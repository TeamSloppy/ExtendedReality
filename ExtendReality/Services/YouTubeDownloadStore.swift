import Foundation
import Observation
@preconcurrency import YouTubeKit

struct YouTubeDownload: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let youtubeVideoID: String?
    let title: String
    let channelTitle: String
    let fileName: String
    let thumbnailURL: URL?
    let resolution: Int?
    let createdAt: Date
}

struct YouTubePendingDownload: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?
    var resolution: Int?
}

enum YouTubeDownloadQuality: Int, CaseIterable, Codable, Identifiable, Sendable {
    case best = 0
    case p1080 = 1080
    case p720 = 720
    case p480 = 480
    case p360 = 360
    case p240 = 240
    case p144 = 144

    var id: Self { self }

    var title: String {
        switch self {
        case .best: "Best"
        default: "\(rawValue)p"
        }
    }

    var maximumResolution: Int? {
        self == .best ? nil : rawValue
    }
}

enum YouTubeDownloadActivity: Equatable, Sendable {
    case resolving
    case downloading(progress: Double?, receivedBytes: Int64, totalBytes: Int64?)

    var title: String {
        switch self {
        case .resolving: "Preparing…"
        case .downloading(let progress, _, _):
            if let progress {
                "\(Int((progress * 100).rounded()))%"
            } else {
                "Downloading…"
            }
        }
    }

    var progress: Double? {
        guard case .downloading(let progress, _, _) = self else { return nil }
        return progress
    }

    var byteDetail: String? {
        guard case .downloading(_, let receivedBytes, let totalBytes) = self else { return nil }
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        guard let totalBytes else { return received }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(received) of \(total)"
    }
}

enum YouTubeDownloadError: LocalizedError {
    case noPlayableStream
    case invalidLocalFile
    case missingFile

    var errorDescription: String? {
        switch self {
        case .noPlayableStream:
            "No downloadable MP4 stream with video and audio is available for this video."
        case .invalidLocalFile:
            "The selected file is not a readable video."
        case .missingFile:
            "The downloaded video is no longer available on disk."
        }
    }
}

@MainActor
@Observable
final class YouTubeDownloadStore {
    private(set) var downloads: [YouTubeDownload] = []
    private(set) var pendingDownloads: [YouTubePendingDownload] = []
    private(set) var activityByVideoID: [String: YouTubeDownloadActivity] = [:]
    private(set) var errorMessage: String?
    var selectedQuality: YouTubeDownloadQuality {
        didSet {
            userDefaults.set(selectedQuality.rawValue, forKey: Self.qualityDefaultsKey)
        }
    }

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let directoryURL: URL
    @ObservationIgnored private let manifestURL: URL
    @ObservationIgnored private let userDefaults: UserDefaults

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        selectedQuality = YouTubeDownloadQuality(
            rawValue: userDefaults.integer(forKey: Self.qualityDefaultsKey)
        ) ?? .best
        let baseURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.directoryURL = baseURL
        manifestURL = baseURL.appendingPathComponent("downloads.json", isDirectory: false)
        prepareDirectory()
        loadManifest()
    }

    func activity(for videoID: String) -> YouTubeDownloadActivity? {
        activityByVideoID[videoID]
    }

    func contains(videoID: String) -> Bool {
        downloads.contains { $0.youtubeVideoID == videoID }
    }

    func fileURL(for download: YouTubeDownload) -> URL? {
        let url = directoryURL.appendingPathComponent(download.fileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ video: YouTubeVideo) {
        guard activityByVideoID[video.id] == nil, !contains(videoID: video.id) else { return }
        let quality = selectedQuality
        activityByVideoID[video.id] = .resolving
        pendingDownloads.append(
            YouTubePendingDownload(
                id: video.id,
                title: video.title,
                channelTitle: video.channelTitle,
                thumbnailURL: video.thumbnailURL,
                resolution: nil
            )
        )
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let streams = try await YouTube(videoID: video.id).streams
                let compatibleStreams = streams
                    .filterVideoAndAudio()
                    .filter({ $0.fileExtension == .mp4 && $0.isNativelyPlayable })
                let preferredStreams: [YouTubeKit.Stream]
                if let maximumResolution = quality.maximumResolution {
                    preferredStreams = compatibleStreams.filter {
                        ($0.videoResolution ?? .max) <= maximumResolution
                    }
                } else {
                    preferredStreams = compatibleStreams
                }
                guard let stream = (preferredStreams.isEmpty ? compatibleStreams : preferredStreams)
                    .highestResolutionStream() else {
                    throw YouTubeDownloadError.noPlayableStream
                }

                guard !Task.isCancelled else { return }
                if let index = pendingDownloads.firstIndex(where: { $0.id == video.id }) {
                    pendingDownloads[index].resolution = stream.videoResolution
                }
                activityByVideoID[video.id] = .downloading(
                    progress: 0,
                    receivedBytes: 0,
                    totalBytes: nil
                )
                let transfer = YouTubeDownloadTransfer()
                let temporaryURL = try await transfer.download(from: stream.url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, activityByVideoID[video.id] != nil else { return }
                        activityByVideoID[video.id] = .downloading(
                            progress: progress.fraction,
                            receivedBytes: progress.receivedBytes,
                            totalBytes: progress.totalBytes
                        )
                    }
                }
                defer { try? fileManager.removeItem(at: temporaryURL) }
                guard !Task.isCancelled else { return }

                let download = try installDownloadedFile(
                    from: temporaryURL,
                    youtubeVideoID: video.id,
                    title: video.title,
                    channelTitle: video.channelTitle,
                    thumbnailURL: video.thumbnailURL,
                    resolution: stream.videoResolution,
                    preferredExtension: "mp4"
                )
                downloads.insert(download, at: 0)
                try saveManifest()
                activityByVideoID[video.id] = nil
                pendingDownloads.removeAll { $0.id == video.id }
            } catch is CancellationError {
                activityByVideoID[video.id] = nil
                pendingDownloads.removeAll { $0.id == video.id }
            } catch {
                activityByVideoID[video.id] = nil
                pendingDownloads.removeAll { $0.id == video.id }
                errorMessage = error.localizedDescription
            }
        }
    }

    func importVideo(from sourceURL: URL) throws {
        errorMessage = nil
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw YouTubeDownloadError.invalidLocalFile
        }
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let download = try installDownloadedFile(
            from: sourceURL,
            youtubeVideoID: nil,
            title: title,
            channelTitle: "On My Device",
            thumbnailURL: nil,
            resolution: nil,
            preferredExtension: fileExtension
        )
        downloads.insert(download, at: 0)
        try saveManifest()
    }

    func delete(_ download: YouTubeDownload) {
        if let url = fileURL(for: download) {
            try? fileManager.removeItem(at: url)
        }
        downloads.removeAll { $0.id == download.id }
        try? saveManifest()
    }

    func clearError() {
        errorMessage = nil
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func installDownloadedFile(
        from sourceURL: URL,
        youtubeVideoID: String?,
        title: String,
        channelTitle: String,
        thumbnailURL: URL?,
        resolution: Int?,
        preferredExtension: String
    ) throws -> YouTubeDownload {
        prepareDirectory()
        let id = UUID()
        let safeExtension = preferredExtension
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        let fileName = "\(id.uuidString).\(safeExtension.isEmpty ? "mp4" : safeExtension)"
        let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return YouTubeDownload(
            id: id,
            youtubeVideoID: youtubeVideoID,
            title: title,
            channelTitle: channelTitle,
            fileName: fileName,
            thumbnailURL: thumbnailURL,
            resolution: resolution,
            createdAt: Date()
        )
    }

    private func prepareDirectory() {
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([YouTubeDownload].self, from: data) else {
            downloads = []
            return
        }
        downloads = stored
            .filter { fileURL(for: $0) != nil }
            .sorted { $0.createdAt > $1.createdAt }
        try? saveManifest()
    }

    private func saveManifest() throws {
        let data = try JSONEncoder().encode(downloads)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ExtendReality", isDirectory: true)
            .appendingPathComponent("YouTubeDownloads", isDirectory: true)
    }

    private static let qualityDefaultsKey = "youtube.downloadQuality"
}

private struct YouTubeTransferProgress: Sendable {
    let fraction: Double?
    let receivedBytes: Int64
    let totalBytes: Int64?
}

private final class YouTubeDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadedURL: URL?
    private var session: URLSession?
    private var isCancelled = false
    private var progressHandler: (@Sendable (YouTubeTransferProgress) -> Void)?

    func download(
        from url: URL,
        progress: @escaping @Sendable (YouTubeTransferProgress) -> Void
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.continuation = continuation
                progressHandler = progress
                let configuration = URLSessionConfiguration.default
                configuration.waitsForConnectivity = true
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.downloadTask(with: url)
                downloadTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let fraction = totalBytes.map {
            min(max(Double(totalBytesWritten) / Double($0), 0), 1)
        }
        progressHandler?(
            YouTubeTransferProgress(
                fraction: fraction,
                receivedBytes: totalBytesWritten,
                totalBytes: totalBytes
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: location, to: destination)
            lock.lock()
            downloadedURL = destination
            lock.unlock()
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(with: .failure(error))
            return
        }
        guard let response = task.response as? HTTPURLResponse,
              200 ..< 300 ~= response.statusCode else {
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }

        lock.lock()
        let downloadedURL = downloadedURL
        lock.unlock()
        guard let downloadedURL else {
            finish(with: .failure(URLError(.cannotCreateFile)))
            return
        }
        finish(with: .success(downloadedURL))
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let task = downloadTask
        lock.unlock()
        task?.cancel()
    }

    private func finish(with result: Result<URL, any Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        downloadTask = nil
        progressHandler = nil
        let session = session
        self.session = nil
        let temporaryURL = downloadedURL
        downloadedURL = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        if case .failure = result, let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        continuation.resume(with: result)
    }
}
