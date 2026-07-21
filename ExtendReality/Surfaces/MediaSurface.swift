import AVFoundation
import AVKit
import ImageIO
import Observation
@preconcurrency import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum MediaPresentationMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case twoDimensional
    case sourceStereo
    case generatedStereo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoDimensional: "2D"
        case .sourceStereo: "Source 3D"
        case .generatedStereo: "AI 3D"
        }
    }

    var systemImage: String {
        switch self {
        case .twoDimensional: "rectangle"
        case .sourceStereo: "view.3d"
        case .generatedStereo: "sparkles.rectangle.stack"
        }
    }
}

enum MediaLibraryFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case photos
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        }
    }

    func includes(_ mediaType: PHAssetMediaType) -> Bool {
        switch self {
        case .all:
            mediaType == .image || mediaType == .video
        case .photos:
            mediaType == .image
        case .videos:
            mediaType == .video
        }
    }
}

struct SpatialPhotoStereoPair {
    let left: UIImage
    let right: UIImage
}

enum MediaImportError: LocalizedError {
    case unsupportedImage
    case unavailablePhotoData

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: "The selected image could not be decoded."
        case .unavailablePhotoData: "The selected photo or video could not be loaded."
        }
    }
}

enum SpatialPhotoDecoder {
    struct DecodedPhoto {
        let primary: UIImage
        let stereoPair: SpatialPhotoStereoPair?
    }

    struct StereoImageIndices: Equatable {
        let left: Int
        let right: Int
    }

    static func decode(_ data: Data) throws -> DecodedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MediaImportError.unsupportedImage
        }

        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let primary = image(at: primaryIndex, in: source) ?? UIImage(data: data) else {
            throw MediaImportError.unsupportedImage
        }

        guard let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let indices = stereoImageIndices(in: sourceProperties),
              indices.left < CGImageSourceGetCount(source),
              indices.right < CGImageSourceGetCount(source),
              let left = image(at: indices.left, in: source),
              let right = image(at: indices.right, in: source) else {
            return DecodedPhoto(primary: primary, stereoPair: nil)
        }

        return DecodedPhoto(
            primary: primary,
            stereoPair: SpatialPhotoStereoPair(left: left, right: right)
        )
    }

    static func stereoImageIndices(in properties: [CFString: Any]) -> StereoImageIndices? {
        guard let groups = properties[kCGImagePropertyGroups] as? [[CFString: Any]] else {
            return nil
        }
        let stereoType = kCGImagePropertyGroupTypeStereoPair as String
        guard let stereoGroup = groups.first(where: {
            ($0[kCGImagePropertyGroupType] as? String) == stereoType
        }),
        let left = integer(stereoGroup[kCGImagePropertyGroupImageIndexLeft]),
        let right = integer(stereoGroup[kCGImagePropertyGroupImageIndexRight]),
        left >= 0,
        right >= 0,
        left != right else {
            return nil
        }
        return StereoImageIndices(left: left, right: right)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func image(at index: Int, in source: CGImageSource) -> UIImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientationValue = integer(properties?[kCGImagePropertyOrientation]) ?? 1
        let orientation = UIImage.Orientation(imagePropertyOrientation: orientationValue)
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}

private extension UIImage.Orientation {
    init(imagePropertyOrientation: Int) {
        self = switch imagePropertyOrientation {
        case 2: .upMirrored
        case 3: .down
        case 4: .downMirrored
        case 5: .leftMirrored
        case 6: .right
        case 7: .rightMirrored
        case 8: .left
        default: .up
        }
    }
}

@MainActor
@Observable
final class MediaSession: InputTarget {
    private(set) var image: UIImage?
    private(set) var spatialPhoto: SpatialPhotoStereoPair?
    private(set) var fileName: String?
    private(set) var isPlaying = false
    private(set) var presentationMode: MediaPresentationMode = .twoDimensional
    private(set) var generatedStereoStatus: GeneratedStereoStatus = .idle
    private(set) var stereoDisparityPercent = StereoDepthSettings.defaultDisparityPercent
    private(set) var lastErrorMessage: String?
    private(set) var photoLibraryAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var photoLibraryFilter: MediaLibraryFilter = .all
    private(set) var photoLibraryAssets: [PHAsset] = []
    private(set) var photoLibraryThumbnails: [String: UIImage] = [:]
    private(set) var isLoadingPhotoLibrary = false
    private(set) var photoLibraryFirstVisibleIndex = 0
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private(set) var latestStereoDepthFrame: StereoDepthFrame?
    @ObservationIgnored private var stereoFrameSource: (any StereoFrameSource)?
    @ObservationIgnored private let depthEstimator = StereoDepthEstimator()
    @ObservationIgnored private var depthTask: Task<Void, Never>?
    @ObservationIgnored private var frameAvailabilityTask: Task<Void, Never>?
    @ObservationIgnored private var lastDepthRequestTime: CFTimeInterval = -.infinity
    @ObservationIgnored private var mediaGeneration: UInt64 = 0
    @ObservationIgnored private var isFullSideBySideDisplayReady = false
    @ObservationIgnored private let photoImageManager = PHCachingImageManager()
    @ObservationIgnored private var allPhotoLibraryAssets: [PHAsset] = []
    @ObservationIgnored private var requestedThumbnailIDs: Set<String> = []
    @ObservationIgnored private var photoLibraryColumns = 5
    @ObservationIgnored private var photoLibraryVisibleRows = 3
    @ObservationIgnored private var pressedPhotoAssetID: String?
    @ObservationIgnored private let playbackStateDidChange: () -> Void

    init(playbackStateDidChange: @escaping () -> Void = {}) {
        self.playbackStateDidChange = playbackStateDidChange
    }

    var isSpatialPhoto: Bool { spatialPhoto != nil }
    var isVideo: Bool { player != nil }
    var isGeneratedStereoActive: Bool {
        isVideo && presentationMode == .generatedStereo
    }

    var isShowingPhotoLibrary: Bool {
        image == nil && player == nil
    }

    var availablePresentationModes: [MediaPresentationMode] {
        if isSpatialPhoto { return [.twoDimensional, .sourceStereo] }
        if isVideo { return [.twoDimensional, .generatedStereo] }
        return [.twoDimensional]
    }

    func requestPhotoLibraryAccess() {
        guard !isLoadingPhotoLibrary else { return }

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoLibraryAuthorizationStatus = currentStatus
        switch currentStatus {
        case .authorized, .limited:
            loadPhotoLibrary()
        case .notDetermined:
            isLoadingPhotoLibrary = true
            Task { [weak self] in
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                guard let self else { return }
                photoLibraryAuthorizationStatus = status
                isLoadingPhotoLibrary = false
                if status == .authorized || status == .limited {
                    loadPhotoLibrary()
                }
            }
        case .denied, .restricted:
            allPhotoLibraryAssets = []
            photoLibraryAssets = []
            photoLibraryThumbnails = [:]
        @unknown default:
            allPhotoLibraryAssets = []
            photoLibraryAssets = []
            photoLibraryThumbnails = [:]
        }
    }

    func setPhotoLibraryFilter(_ filter: MediaLibraryFilter) {
        guard photoLibraryFilter != filter else { return }
        photoLibraryFilter = filter
        applyPhotoLibraryFilter()
    }

    func showPhotoLibrary() {
        resetGeneratedStereo()
        player?.pause()
        player = nil
        stereoFrameSource = nil
        image = nil
        spatialPhoto = nil
        fileName = nil
        presentationMode = .twoDimensional
        isPlaying = false
        lastErrorMessage = nil
        playbackStateDidChange()
        requestPhotoLibraryAccess()
    }

    func updatePhotoLibraryGrid(columns: Int, visibleRows: Int) {
        photoLibraryColumns = max(1, columns)
        photoLibraryVisibleRows = max(1, visibleRows)
        photoLibraryFirstVisibleIndex = clampedPhotoLibraryStart(photoLibraryFirstVisibleIndex)
    }

    func requestThumbnail(for asset: PHAsset, targetSize: CGSize) {
        let identifier = asset.localIdentifier
        guard photoLibraryThumbnails[identifier] == nil,
              requestedThumbnailIDs.insert(identifier).inserted else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        photoImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let image else { return }
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            guard !isCancelled else { return }
            Task { @MainActor [weak self] in
                self?.photoLibraryThumbnails[identifier] = image
            }
        }
    }

    func thumbnail(for asset: PHAsset) -> UIImage? {
        photoLibraryThumbnails[asset.localIdentifier]
    }

    func importFile(_ sourceURL: URL) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let imports = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let destination = imports.appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try loadLocalURL(destination)
    }

    func loadPhotoData(_ data: Data, suggestedName: String = "Photo") throws {
        resetGeneratedStereo()
        let decoded = try SpatialPhotoDecoder.decode(data)
        player?.pause()
        player = nil
        stereoFrameSource = nil
        image = decoded.primary
        spatialPhoto = decoded.stereoPair
        presentationMode = decoded.stereoPair == nil ? .twoDimensional : .sourceStereo
        fileName = decoded.stereoPair == nil ? suggestedName : "Spatial Photo"
        isPlaying = false
        lastErrorMessage = nil
        playbackStateDidChange()
    }

    func importMediaData(_ data: Data, filenameExtension: String) throws {
        let imports = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let destination = imports
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(filenameExtension)
        try data.write(to: destination, options: .atomic)
        try loadLocalURL(destination)
    }

    func setPresentationMode(_ mode: MediaPresentationMode) {
        switch mode {
        case .twoDimensional:
            resetGeneratedStereo()
        case .sourceStereo:
            guard spatialPhoto != nil else { return }
            resetGeneratedStereo()
        case .generatedStereo:
            guard isVideo else { return }
            generatedStereoStatus = .preparing
            latestStereoDepthFrame = nil
            isFullSideBySideDisplayReady = false
            lastDepthRequestTime = -.infinity
        }
        presentationMode = mode
        if mode == .generatedStereo {
            startFrameAvailabilityTimeout()
        }
    }

    func setStereoDisparityPercent(_ value: Double) {
        stereoDisparityPercent = StereoDepthSettings.clampedDisparityPercent(value)
    }

    func reportImportError(_ error: any Error) {
        lastErrorMessage = error.localizedDescription
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        playbackStateDidChange()
    }

    func seek(seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, current + seconds), preferredTimescale: 600))
        depthTask?.cancel()
        depthTask = nil
        latestStereoDepthFrame = nil
        lastDepthRequestTime = -.infinity
        mediaGeneration &+= 1
        if presentationMode == .generatedStereo {
            generatedStereoStatus = .preparing
            startFrameAvailabilityTimeout()
        }
        Task { await depthEstimator.reset() }
    }

    func copyStereoVideoFrame(forHostTime hostTime: CFTimeInterval) -> StereoVideoFrame? {
        guard presentationMode == .generatedStereo else { return nil }
        guard let frame = stereoFrameSource?.copyFrame(forHostTime: hostTime) else { return nil }
        frameAvailabilityTask?.cancel()
        frameAvailabilityTask = nil
        return frame
    }

    func evaluateStereoThermalState() {
        guard presentationMode == .generatedStereo else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            failGeneratedStereo(
                status: .unavailable("AI 3D paused because the iPhone is too hot.")
            )
        case .serious:
            if latestStereoDepthFrame != nil, isFullSideBySideDisplayReady {
                generatedStereoStatus = .thermallyDegraded
            }
        case .nominal, .fair:
            if latestStereoDepthFrame != nil, isFullSideBySideDisplayReady {
                generatedStereoStatus = .active
            }
        @unknown default:
            break
        }
    }

    func submitDepthFrameIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard presentationMode == .generatedStereo else { return }
        let thermalState = ProcessInfo.processInfo.thermalState
        guard let framesPerSecond = StereoThermalPolicy.depthFramesPerSecond(for: thermalState) else {
            failGeneratedStereo(
                status: .unavailable("AI 3D paused because the iPhone is too hot.")
            )
            return
        }

        let now = CACurrentMediaTime()
        guard depthTask == nil,
              now - lastDepthRequestTime >= 1 / Double(framesPerSecond) else { return }
        lastDepthRequestTime = now
        let generation = mediaGeneration
        let source = StereoPixelBuffer(value: pixelBuffer)
        let estimator = depthEstimator
        depthTask = Task { [weak self] in
            do {
                let depth = try await estimator.estimate(source)
                guard !Task.isCancelled else { return }
                self?.finishDepthEstimation(depth, generation: generation)
            } catch is CancellationError {
                self?.depthTask = nil
            } catch {
                self?.finishDepthEstimation(error: error, generation: generation)
            }
        }
    }

    func reportWaitingForFullSideBySideDisplay() {
        guard presentationMode == .generatedStereo else { return }
        isFullSideBySideDisplayReady = false
        generatedStereoStatus = .preparing
    }

    func reportFullSideBySideDisplayReady() {
        guard presentationMode == .generatedStereo else { return }
        isFullSideBySideDisplayReady = true
        guard latestStereoDepthFrame != nil else {
            generatedStereoStatus = .preparing
            return
        }
        generatedStereoStatus = ProcessInfo.processInfo.thermalState == .serious
            ? .thermallyDegraded
            : .active
    }

    func reportFullSideBySideDisplayUnavailable() {
        guard presentationMode == .generatedStereo else { return }
        failGeneratedStereo(
            status: .unavailable("Full SBS 3840×1080 was not detected. AI 3D returned to 2D.")
        )
    }

    func reportStereoRendererFailure(_ message: String) {
        guard presentationMode == .generatedStereo else { return }
        failGeneratedStereo(status: .failed(message))
    }

    func handle(_ command: InputCommand) {
        switch command {
        case .pointerDown(let position) where isShowingPhotoLibrary:
            pressedPhotoAssetID = photoLibraryAsset(at: position)?.localIdentifier
        case .pointerUp(let position) where isShowingPhotoLibrary:
            let asset = photoLibraryAsset(at: position)
            defer { pressedPhotoAssetID = nil }
            guard asset?.localIdentifier == pressedPhotoAssetID, let asset else { return }
            loadPhotoLibraryAsset(asset)
        case .scroll(let delta) where isShowingPhotoLibrary:
            scrollPhotoLibrary(by: delta.dy)
        case .back where !isShowingPhotoLibrary:
            showPhotoLibrary()
        case .media(let media):
            switch media {
            case .play:
                guard let player else { return }
                player.play()
                isPlaying = true
                playbackStateDidChange()
            case .pause:
                guard let player else { return }
                player.pause()
                isPlaying = false
                playbackStateDidChange()
            case .togglePlayback:
                togglePlayback()
            case .seek(let seconds):
                seek(seconds: seconds)
            }
        default:
            break
        }
    }

    private func loadPhotoLibrary() {
        isLoadingPhotoLibrary = true
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        allPhotoLibraryAssets = assets
        requestedThumbnailIDs = []
        photoLibraryThumbnails = [:]
        applyPhotoLibraryFilter()
        isLoadingPhotoLibrary = false
    }

    private func applyPhotoLibraryFilter() {
        photoLibraryAssets = allPhotoLibraryAssets.filter {
            photoLibraryFilter.includes($0.mediaType)
        }
        photoLibraryFirstVisibleIndex = 0
        pressedPhotoAssetID = nil
    }

    private func photoLibraryAsset(at position: CGPoint) -> PHAsset? {
        guard !photoLibraryAssets.isEmpty else { return nil }
        let column = min(photoLibraryColumns - 1, max(0, Int(position.x * CGFloat(photoLibraryColumns))))
        let row = min(photoLibraryVisibleRows - 1, max(0, Int(position.y * CGFloat(photoLibraryVisibleRows))))
        let index = photoLibraryFirstVisibleIndex + row * photoLibraryColumns + column
        guard photoLibraryAssets.indices.contains(index) else { return nil }
        return photoLibraryAssets[index]
    }

    private func scrollPhotoLibrary(by delta: CGFloat) {
        guard !photoLibraryAssets.isEmpty, delta != 0 else { return }
        let rowDelta = delta > 0 ? photoLibraryColumns : -photoLibraryColumns
        photoLibraryFirstVisibleIndex = clampedPhotoLibraryStart(photoLibraryFirstVisibleIndex + rowDelta)
    }

    private func clampedPhotoLibraryStart(_ value: Int) -> Int {
        let visibleCount = photoLibraryColumns * photoLibraryVisibleRows
        let maximumStart = max(0, photoLibraryAssets.count - visibleCount)
        let rowAlignedValue = max(0, value / photoLibraryColumns * photoLibraryColumns)
        return min(rowAlignedValue, maximumStart)
    }

    private func loadPhotoLibraryAsset(_ asset: PHAsset) {
        isLoadingPhotoLibrary = true
        lastErrorMessage = nil
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
                [weak self] avAsset, _, info in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    isLoadingPhotoLibrary = false
                    if let avAsset {
                        loadVideoAsset(avAsset, suggestedName: "Video")
                    } else {
                        reportPhotoLibraryLoadFailure(info)
                    }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                [weak self] data, _, _, info in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    isLoadingPhotoLibrary = false
                    guard let data else {
                        reportPhotoLibraryLoadFailure(info)
                        return
                    }
                    do {
                        try loadPhotoData(data)
                    } catch {
                        reportImportError(error)
                    }
                }
            }
        }
    }

    private func loadVideoAsset(_ asset: AVAsset, suggestedName: String) {
        resetGeneratedStereo()
        image = nil
        spatialPhoto = nil
        presentationMode = .twoDimensional
        fileName = suggestedName
        let item = AVPlayerItem(asset: asset)
        stereoFrameSource = AVPlayerStereoFrameSource(item: item)
        player = AVPlayer(playerItem: item)
        lastErrorMessage = nil
        isPlaying = false
        playbackStateDidChange()
    }

    private func reportPhotoLibraryLoadFailure(_ info: [AnyHashable: Any]?) {
        if let error = info?[PHImageErrorKey] as? any Error {
            reportImportError(error)
        } else {
            reportImportError(MediaImportError.unavailablePhotoData)
        }
    }

    private func loadLocalURL(_ url: URL) throws {
        resetGeneratedStereo()
        fileName = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            try loadPhotoData(Data(contentsOf: url), suggestedName: url.lastPathComponent)
            return
        }
        image = nil
        spatialPhoto = nil
        presentationMode = .twoDimensional
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        stereoFrameSource = AVPlayerStereoFrameSource(item: item)
        player = AVPlayer(playerItem: item)
        lastErrorMessage = nil
        isPlaying = false
        playbackStateDidChange()
    }

    private func finishDepthEstimation(_ frame: StereoDepthFrame, generation: UInt64) {
        depthTask = nil
        guard generation == mediaGeneration,
              presentationMode == .generatedStereo else { return }
        latestStereoDepthFrame = frame
        guard isFullSideBySideDisplayReady else {
            generatedStereoStatus = .preparing
            return
        }
        generatedStereoStatus = ProcessInfo.processInfo.thermalState == .serious
            ? .thermallyDegraded
            : .active
    }

    private func finishDepthEstimation(error: any Error, generation: UInt64) {
        depthTask = nil
        guard generation == mediaGeneration,
              presentationMode == .generatedStereo else { return }
        failGeneratedStereo(status: .failed(error.localizedDescription))
    }

    private func failGeneratedStereo(status: GeneratedStereoStatus) {
        depthTask?.cancel()
        depthTask = nil
        frameAvailabilityTask?.cancel()
        frameAvailabilityTask = nil
        latestStereoDepthFrame = nil
        isFullSideBySideDisplayReady = false
        presentationMode = .twoDimensional
        generatedStereoStatus = status
        mediaGeneration &+= 1
        Task { await depthEstimator.reset() }
    }

    private func resetGeneratedStereo() {
        depthTask?.cancel()
        depthTask = nil
        frameAvailabilityTask?.cancel()
        frameAvailabilityTask = nil
        latestStereoDepthFrame = nil
        generatedStereoStatus = .idle
        isFullSideBySideDisplayReady = false
        lastDepthRequestTime = -.infinity
        mediaGeneration &+= 1
        Task { await depthEstimator.reset() }
    }

    private func startFrameAvailabilityTimeout() {
        frameAvailabilityTask?.cancel()
        let generation = mediaGeneration
        frameAvailabilityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  generation == mediaGeneration,
                  presentationMode == .generatedStereo else { return }
            failGeneratedStereo(
                status: .unavailable(
                    "Video frames are unavailable for AI 3D. The content may be protected."
                )
            )
        }
    }
}

struct MediaSurfaceView: View {
    let session: MediaSession

    var body: some View {
        Group {
            if let image = session.image {
                if session.presentationMode == .sourceStereo, let pair = session.spatialPhoto {
                    SpatialPhotoSideBySideView(pair: pair)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else if let player = session.player {
                if session.presentationMode == .generatedStereo {
                    ZStack {
                        Color.black
                        ProgressView("Rendering AI 3D on the glasses…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                } else {
                    VideoPlayer(player: player)
                }
            } else {
                PhotoLibraryGridView(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            session.requestPhotoLibraryAccess()
        }
    }
}

private struct PhotoLibraryGridView: View {
    let session: MediaSession

    var body: some View {
        switch session.photoLibraryAuthorizationStatus {
        case .authorized, .limited:
            if session.isLoadingPhotoLibrary && session.photoLibraryAssets.isEmpty {
                ProgressView("Loading photo library…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if session.photoLibraryAssets.isEmpty {
                ContentUnavailableView(
                    session.photoLibraryFilter.emptyTitle,
                    systemImage: session.photoLibraryFilter.systemImage,
                    description: Text(session.photoLibraryFilter.emptyDescription)
                )
                .foregroundStyle(.white)
            } else {
                photoGrid
            }
        case .notDetermined:
            ProgressView("Requesting Photos access…")
                .tint(.white)
                .foregroundStyle(.white)
        case .denied, .restricted:
            ContentUnavailableView(
                "Photos access is required",
                systemImage: "photo.badge.exclamationmark",
                description: Text("Allow Photos access for ExtendReality in Settings.")
            )
            .foregroundStyle(.white)
        @unknown default:
            EmptyView()
        }
    }

    private var photoGrid: some View {
        GeometryReader { proxy in
            let layout = PhotoLibraryGridLayout(size: proxy.size)
            let visibleAssets = Array(
                session.photoLibraryAssets
                    .dropFirst(session.photoLibraryFirstVisibleIndex)
                    .prefix(layout.capacity)
            )

            LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                ForEach(visibleAssets, id: \.localIdentifier) { asset in
                    PhotoLibraryThumbnailView(
                        asset: asset,
                        image: session.thumbnail(for: asset)
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .task(id: asset.localIdentifier) {
                        session.requestThumbnail(
                            for: asset,
                            targetSize: layout.thumbnailTargetSize
                        )
                    }
                }
            }
            .padding(layout.spacing)
            .overlay(alignment: .topTrailing) {
                Text("\(session.photoLibraryAssets.count) items")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(12)
            }
            .onAppear {
                session.updatePhotoLibraryGrid(
                    columns: layout.columnCount,
                    visibleRows: layout.rowCount
                )
            }
            .onChange(of: proxy.size) { _, newSize in
                let newLayout = PhotoLibraryGridLayout(size: newSize)
                session.updatePhotoLibraryGrid(
                    columns: newLayout.columnCount,
                    visibleRows: newLayout.rowCount
                )
            }
        }
        .clipped()
    }
}

private extension MediaLibraryFilter {
    var emptyTitle: String {
        switch self {
        case .all: "No photos or videos"
        case .photos: "No photos"
        case .videos: "No videos"
        }
    }

    var emptyDescription: String {
        switch self {
        case .all: "Your photo library is empty."
        case .photos: "There are no photos matching this filter."
        case .videos: "There are no videos matching this filter."
        }
    }
}

private struct PhotoLibraryGridLayout {
    let columnCount: Int
    let rowCount: Int
    let spacing: CGFloat = 4

    init(size: CGSize) {
        columnCount = max(3, Int(size.width / 150))
        rowCount = max(2, Int(size.height / 150))
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var capacity: Int { columnCount * rowCount }

    var thumbnailTargetSize: CGSize {
        CGSize(width: 400, height: 400)
    }
}

private struct PhotoLibraryThumbnailView: View {
    let asset: PHAsset
    let image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(.white.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if asset.mediaType == .video {
                Label(
                    asset.duration.formattedDuration,
                    systemImage: "video.fill"
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let seconds = max(0, Int(self.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct SpatialPhotoSideBySideView: View {
    let pair: SpatialPhotoStereoPair

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                eyeView(pair.left, width: proxy.size.width / 2)
                eyeView(pair.right, width: proxy.size.width / 2)
            }
        }
        .background(Color.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spatial photo in side-by-side 3D")
    }

    private func eyeView(_ image: UIImage, width: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipped()
    }
}

#if DEBUG
#Preview("Media Surface — Empty") {
    MediaSurfaceView(session: MediaSession())
        .frame(width: 960, height: 540)
        .preferredColorScheme(.dark)
}
#endif
