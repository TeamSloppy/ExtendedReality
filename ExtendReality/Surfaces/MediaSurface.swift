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
    case spatial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .spatial: "Spatial"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        case .spatial: "view.3d"
        }
    }

    func includes(_ mediaType: PHAssetMediaType) -> Bool {
        includes(mediaType: mediaType, mediaSubtypes: [])
    }

    func includes(mediaType: PHAssetMediaType, mediaSubtypes: PHAssetMediaSubtype) -> Bool {
        switch self {
        case .all:
            mediaType == .image || mediaType == .video
        case .photos:
            mediaType == .image
        case .videos:
            mediaType == .video
        case .spatial:
            (mediaType == .image || mediaType == .video)
                && mediaSubtypes.contains(.spatialMedia)
        }
    }

    func includes(_ asset: PHAsset) -> Bool {
        includes(mediaType: asset.mediaType, mediaSubtypes: asset.mediaSubtypes)
    }
}

enum MediaSurfaceHitTarget: Equatable {
    case filter(MediaLibraryFilter)
    case files
    case asset(String)
    case previous
    case next
    case close
    case togglePlayback
    case toggleSpatialVideo
}

struct MediaSurfaceInteractionLayout {
    static let sidebarWidth: CGFloat = 0.22
    static let sidebarHeaderHeight: CGFloat = 0.16
    static let sidebarRowHeight: CGFloat = 0.12
    static let viewerControlsTop: CGFloat = 0.82

    static func sidebarTarget(at position: CGPoint) -> MediaSurfaceHitTarget? {
        guard position.x >= 0,
              position.x <= sidebarWidth,
              position.y >= sidebarHeaderHeight else { return nil }
        let row = Int((position.y - sidebarHeaderHeight) / sidebarRowHeight)
        return switch row {
        case 0: .filter(.all)
        case 1: .filter(.photos)
        case 2: .filter(.videos)
        case 3: .filter(.spatial)
        case 4: .files
        default: nil
        }
    }

    static func photoViewerTarget(at position: CGPoint) -> MediaSurfaceHitTarget? {
        guard position.y >= viewerControlsTop else { return nil }
        return switch position.x {
        case 0 ..< (1.0 / 3.0): .previous
        case (1.0 / 3.0) ..< (2.0 / 3.0): .next
        case (2.0 / 3.0) ... 1: .close
        default: nil
        }
    }

    static func videoViewerTarget(at position: CGPoint) -> MediaSurfaceHitTarget? {
        guard position.y >= viewerControlsTop else { return nil }
        return switch position.x {
        case 0 ..< 0.25: .togglePlayback
        case 0.5 ..< 0.75: .toggleSpatialVideo
        case 0.75 ... 1: .close
        default: nil
        }
    }

    static func photoLibraryIndex(
        at position: CGPoint,
        columns: Int,
        rows: Int,
        firstVisibleIndex: Int
    ) -> Int? {
        guard columns > 0,
              rows > 0,
              position.x >= sidebarWidth,
              position.x <= 1,
              position.y >= 0,
              position.y <= 1 else { return nil }

        let gridX = (position.x - sidebarWidth) / (1 - sidebarWidth)
        let column = min(columns - 1, Int(gridX * CGFloat(columns)))
        let row = min(rows - 1, Int(position.y * CGFloat(rows)))
        return firstVisibleIndex + row * columns + column
    }
}

struct SpatialPhotoStereoPair: @unchecked Sendable {
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

private struct SendableAVPlayerItem: @unchecked Sendable {
    let value: AVPlayerItem

    init(_ value: AVPlayerItem) {
        self.value = value
    }
}

private struct SendableImage: @unchecked Sendable {
    let value: UIImage

    init(_ value: UIImage) {
        self.value = value
    }
}

enum SpatialPhotoDecoder {
    struct DecodedPhoto: @unchecked Sendable {
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
    private(set) var videoDuration: TimeInterval = 0
    private(set) var isSourceSpatialVideo = false
    private(set) var videoFrameRotation: VideoFrameRotation = .none
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
    private(set) var selectedPhotoLibraryAssetID: String?
    private(set) var pendingPhotoLibraryAssetID: String?
    private(set) var fileImportRequest: UUID?
    private(set) var player: AVPlayer?
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
    @ObservationIgnored private var hasLoadedPhotoLibrary = false
    @ObservationIgnored private var requestedThumbnailIDs: Set<String> = []
    @ObservationIgnored private var thumbnailRequestIDs: [String: PHImageRequestID] = [:]
    @ObservationIgnored private var mediaRequestID: PHImageRequestID?
    @ObservationIgnored private var photoLibraryColumns = 5
    @ObservationIgnored private var photoLibraryVisibleRows = 3
    @ObservationIgnored private var photoLibraryLoadGeneration: UInt64 = 0
    @ObservationIgnored private var pressedTarget: MediaSurfaceHitTarget?
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

    var canShowPreviousMedia: Bool {
        guard let selectedPhotoLibraryIndex else { return false }
        return selectedPhotoLibraryIndex > 0
    }

    var canShowNextMedia: Bool {
        guard let selectedPhotoLibraryIndex else { return false }
        return selectedPhotoLibraryIndex < photoLibraryAssets.index(before: photoLibraryAssets.endIndex)
    }

    var formattedVideoDuration: String {
        videoDuration.formattedDuration
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
            if !hasLoadedPhotoLibrary {
                loadPhotoLibrary()
            }
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
        cancelPendingMediaRequest()
        player?.pause()
        player = nil
        stereoFrameSource = nil
        image = nil
        spatialPhoto = nil
        fileName = nil
        presentationMode = .twoDimensional
        isPlaying = false
        videoDuration = 0
        isSourceSpatialVideo = false
        videoFrameRotation = .none
        selectedPhotoLibraryAssetID = nil
        pendingPhotoLibraryAssetID = nil
        lastErrorMessage = nil
        playbackStateDidChange()
        requestPhotoLibraryAccess()
    }

    func updatePhotoLibraryGrid(columns: Int, visibleRows: Int) {
        photoLibraryColumns = max(1, columns)
        photoLibraryVisibleRows = max(1, visibleRows)
        photoLibraryFirstVisibleIndex = clampedPhotoLibraryStart(photoLibraryFirstVisibleIndex)
        trimThumbnailCacheToVisibleAssets()
    }

    func scrollPhotoLibrary(byRows rowCount: Int) {
        guard !photoLibraryAssets.isEmpty, rowCount != 0 else { return }
        photoLibraryFirstVisibleIndex = clampedPhotoLibraryStart(
            photoLibraryFirstVisibleIndex + rowCount * photoLibraryColumns
        )
        trimThumbnailCacheToVisibleAssets()
    }

    func requestThumbnail(for asset: PHAsset, targetSize: CGSize) {
        let identifier = asset.localIdentifier
        guard photoLibraryThumbnails[identifier] == nil,
              requestedThumbnailIDs.insert(identifier).inserted else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let requestID = photoImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let imageBox = image.map(SendableImage.init)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isCancelled || !isDegraded {
                    requestedThumbnailIDs.remove(identifier)
                    thumbnailRequestIDs.removeValue(forKey: identifier)
                }
                guard !isCancelled,
                      visibleThumbnailAssetIDs.contains(identifier),
                      let image = imageBox?.value else { return }
                photoLibraryThumbnails[identifier] = image
            }
        }
        thumbnailRequestIDs[identifier] = requestID
    }

    func thumbnail(for asset: PHAsset) -> UIImage? {
        photoLibraryThumbnails[asset.localIdentifier]
    }

    private var visibleThumbnailAssetIDs: Set<String> {
        let visibleCount = photoLibraryColumns * photoLibraryVisibleRows
        return Set(
            photoLibraryAssets
                .dropFirst(photoLibraryFirstVisibleIndex)
                .prefix(visibleCount)
                .map(\.localIdentifier)
        )
    }

    private func trimThumbnailCacheToVisibleAssets() {
        let retainedIDs = visibleThumbnailAssetIDs
        let obsoleteRequests = thumbnailRequestIDs.filter {
            !retainedIDs.contains($0.key)
        }
        for (identifier, requestID) in obsoleteRequests {
            photoImageManager.cancelImageRequest(requestID)
            thumbnailRequestIDs.removeValue(forKey: identifier)
            requestedThumbnailIDs.remove(identifier)
        }
        let retainedThumbnails = photoLibraryThumbnails.filter {
            retainedIDs.contains($0.key)
        }
        if retainedThumbnails.count != photoLibraryThumbnails.count {
            photoLibraryThumbnails = retainedThumbnails
        }
    }

    private func clearThumbnailCache() {
        for requestID in thumbnailRequestIDs.values {
            photoImageManager.cancelImageRequest(requestID)
        }
        thumbnailRequestIDs = [:]
        requestedThumbnailIDs = []
        photoLibraryThumbnails = [:]
    }

    private func cancelPendingMediaRequest() {
        photoLibraryLoadGeneration &+= 1
        if let mediaRequestID {
            photoImageManager.cancelImageRequest(mediaRequestID)
            self.mediaRequestID = nil
        }
        pendingPhotoLibraryAssetID = nil
        isLoadingPhotoLibrary = false
    }

    func importFile(_ sourceURL: URL) throws {
        selectedPhotoLibraryAssetID = nil
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
        let decoded = try SpatialPhotoDecoder.decode(data)
        applyDecodedPhoto(decoded, suggestedName: suggestedName)
    }

    private func applyDecodedPhoto(
        _ decoded: SpatialPhotoDecoder.DecodedPhoto,
        suggestedName: String
    ) {
        resetGeneratedStereo()
        player?.pause()
        player = nil
        stereoFrameSource = nil
        image = decoded.primary
        spatialPhoto = decoded.stereoPair
        presentationMode = decoded.stereoPair == nil ? .twoDimensional : .sourceStereo
        fileName = decoded.stereoPair == nil ? suggestedName : "Spatial Photo"
        isPlaying = false
        videoDuration = 0
        isSourceSpatialVideo = false
        videoFrameRotation = .none
        lastErrorMessage = nil
        playbackStateDidChange()
    }

    private func applyPhotoImage(_ loadedImage: UIImage, suggestedName: String) {
        resetGeneratedStereo()
        player?.pause()
        player = nil
        stereoFrameSource = nil
        image = loadedImage
        spatialPhoto = nil
        presentationMode = .twoDimensional
        fileName = suggestedName
        isPlaying = false
        videoDuration = 0
        isSourceSpatialVideo = false
        videoFrameRotation = .none
        lastErrorMessage = nil
        playbackStateDidChange()
    }

    func importMediaData(_ data: Data, filenameExtension: String) throws {
        selectedPhotoLibraryAssetID = nil
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

    func toggleSpatialVideo() {
        setPresentationMode(
            presentationMode == .generatedStereo ? .twoDimensional : .generatedStereo
        )
    }

    func showPreviousMedia() {
        showAdjacentMedia(offset: -1)
    }

    func showNextMedia() {
        showAdjacentMedia(offset: 1)
    }

    func requestFileImport() {
        fileImportRequest = UUID()
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
        case .pointerDown(let position):
            pressedTarget = hitTarget(at: position)
        case .pointerUp(let position):
            let releasedTarget = hitTarget(at: position)
            defer { pressedTarget = nil }
            guard releasedTarget == pressedTarget, let releasedTarget else { return }
            perform(releasedTarget)
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
        hasLoadedPhotoLibrary = true
        clearThumbnailCache()
        applyPhotoLibraryFilter()
        isLoadingPhotoLibrary = false
    }

    private func applyPhotoLibraryFilter() {
        photoLibraryAssets = allPhotoLibraryAssets.filter {
            photoLibraryFilter.includes($0)
        }
        photoLibraryFirstVisibleIndex = 0
        pressedTarget = nil
        trimThumbnailCacheToVisibleAssets()
    }

    private func photoLibraryAsset(at position: CGPoint) -> PHAsset? {
        guard !photoLibraryAssets.isEmpty else { return nil }
        guard let index = MediaSurfaceInteractionLayout.photoLibraryIndex(
            at: position,
            columns: photoLibraryColumns,
            rows: photoLibraryVisibleRows,
            firstVisibleIndex: photoLibraryFirstVisibleIndex
        ) else { return nil }
        guard photoLibraryAssets.indices.contains(index) else { return nil }
        return photoLibraryAssets[index]
    }

    private func scrollPhotoLibrary(by delta: CGFloat) {
        guard delta != 0 else { return }
        scrollPhotoLibrary(byRows: delta > 0 ? 1 : -1)
    }

    private func clampedPhotoLibraryStart(_ value: Int) -> Int {
        let visibleCount = photoLibraryColumns * photoLibraryVisibleRows
        let maximumStart = max(0, photoLibraryAssets.count - visibleCount)
        let rowAlignedValue = max(0, value / photoLibraryColumns * photoLibraryColumns)
        return min(rowAlignedValue, maximumStart)
    }

    func openPhotoLibraryAsset(withIdentifier identifier: String) {
        guard let asset = photoLibraryAssets.first(where: {
            $0.localIdentifier == identifier
        }) else { return }
        loadPhotoLibraryAsset(asset)
    }

    private func loadPhotoLibraryAsset(_ asset: PHAsset) {
        cancelPendingMediaRequest()
        photoLibraryLoadGeneration &+= 1
        let loadGeneration = photoLibraryLoadGeneration
        let identifier = asset.localIdentifier
        pendingPhotoLibraryAssetID = identifier
        isLoadingPhotoLibrary = true
        lastErrorMessage = nil
        if asset.mediaType == .video {
            let duration = asset.duration
            let isSpatial = asset.mediaSubtypes.contains(.spatialMedia)
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            let resultHandler: @Sendable (AVPlayerItem?, [AnyHashable: Any]?) -> Void = {
                [weak self] playerItem, info in
                let itemBox = playerItem.map(SendableAVPlayerItem.init)
                let errorDescription = (info?[PHImageErrorKey] as? any Error)?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard loadGeneration == photoLibraryLoadGeneration else { return }
                    mediaRequestID = nil
                    pendingPhotoLibraryAssetID = nil
                    isLoadingPhotoLibrary = false
                    if let playerItem = itemBox?.value {
                        loadVideoPlayerItem(
                            playerItem,
                            suggestedName: "Video",
                            knownDuration: duration,
                            isSpatial: isSpatial
                        )
                        selectedPhotoLibraryAssetID = identifier
                    } else {
                        reportPhotoLibraryLoadFailure(errorDescription: errorDescription)
                    }
                }
            }
            mediaRequestID = photoImageManager.requestPlayerItem(
                forVideo: asset,
                options: options,
                resultHandler: resultHandler
            )
        } else if asset.mediaSubtypes.contains(.spatialMedia) {
            requestSpatialPhoto(
                asset,
                identifier: identifier,
                loadGeneration: loadGeneration
            )
        } else {
            requestDisplayPhoto(
                asset,
                identifier: identifier,
                loadGeneration: loadGeneration
            )
        }
    }

    private func requestDisplayPhoto(
        _ asset: PHAsset,
        identifier: String,
        loadGeneration: UInt64
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isNetworkAccessAllowed = true
        let resultHandler: @Sendable (UIImage?, [AnyHashable: Any]?) -> Void = {
            [weak self] loadedImage, info in
            let imageBox = loadedImage.map(SendableImage.init)
            let errorDescription = (info?[PHImageErrorKey] as? any Error)?.localizedDescription
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard loadGeneration == photoLibraryLoadGeneration else { return }
                mediaRequestID = nil
                pendingPhotoLibraryAssetID = nil
                isLoadingPhotoLibrary = false
                guard !isCancelled, let image = imageBox?.value else {
                    reportPhotoLibraryLoadFailure(errorDescription: errorDescription)
                    return
                }
                applyPhotoImage(image, suggestedName: "Photo")
                selectedPhotoLibraryAssetID = identifier
            }
        }
        mediaRequestID = photoImageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 2_048, height: 2_048),
            contentMode: .aspectFit,
            options: options,
            resultHandler: resultHandler
        )
    }

    private func requestSpatialPhoto(
        _ asset: PHAsset,
        identifier: String,
        loadGeneration: UInt64
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true
        let resultHandler: @Sendable (Data?, String?, CGImagePropertyOrientation, [AnyHashable: Any]?) -> Void = {
            [weak self] data, _, _, info in
            let errorDescription = (info?[PHImageErrorKey] as? any Error)?.localizedDescription
            guard let data else {
                Task { @MainActor [weak self] in
                    guard let self,
                          loadGeneration == photoLibraryLoadGeneration else { return }
                    mediaRequestID = nil
                    pendingPhotoLibraryAssetID = nil
                    isLoadingPhotoLibrary = false
                    reportPhotoLibraryLoadFailure(errorDescription: errorDescription)
                }
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let decoded = try SpatialPhotoDecoder.decode(data)
                    await self?.finishSpatialPhotoLoad(
                        decoded,
                        identifier: identifier,
                        loadGeneration: loadGeneration
                    )
                } catch {
                    await self?.finishPhotoLoadFailure(
                        error.localizedDescription,
                        loadGeneration: loadGeneration
                    )
                }
            }
        }
        mediaRequestID = photoImageManager.requestImageDataAndOrientation(
            for: asset,
            options: options,
            resultHandler: resultHandler
        )
    }

    private func finishSpatialPhotoLoad(
        _ decoded: SpatialPhotoDecoder.DecodedPhoto,
        identifier: String,
        loadGeneration: UInt64
    ) {
        guard loadGeneration == photoLibraryLoadGeneration else { return }
        mediaRequestID = nil
        pendingPhotoLibraryAssetID = nil
        isLoadingPhotoLibrary = false
        applyDecodedPhoto(decoded, suggestedName: "Spatial Photo")
        selectedPhotoLibraryAssetID = identifier
    }

    private func finishPhotoLoadFailure(
        _ errorDescription: String,
        loadGeneration: UInt64
    ) {
        guard loadGeneration == photoLibraryLoadGeneration else { return }
        mediaRequestID = nil
        pendingPhotoLibraryAssetID = nil
        isLoadingPhotoLibrary = false
        lastErrorMessage = errorDescription
    }

    private func loadVideoPlayerItem(
        _ item: AVPlayerItem,
        suggestedName: String,
        knownDuration: TimeInterval? = nil,
        isSpatial: Bool = false
    ) {
        resetGeneratedStereo()
        image = nil
        spatialPhoto = nil
        presentationMode = .twoDimensional
        fileName = suggestedName
        stereoFrameSource = AVPlayerStereoFrameSource(item: item)
        player = AVPlayer(playerItem: item)
        videoFrameRotation = .none
        lastErrorMessage = nil
        player?.play()
        isPlaying = true
        videoDuration = knownDuration ?? 0
        isSourceSpatialVideo = isSpatial
        playbackStateDidChange()
        loadVideoFrameRotation(from: item.asset)
        if knownDuration == nil {
            loadVideoDuration(from: item.asset)
        }
    }

    private func reportPhotoLibraryLoadFailure(errorDescription: String?) {
        if let errorDescription {
            lastErrorMessage = errorDescription
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
        loadVideoPlayerItem(
            AVPlayerItem(asset: AVURLAsset(url: url)),
            suggestedName: url.lastPathComponent
        )
    }

    private var selectedPhotoLibraryIndex: Int? {
        guard let selectedPhotoLibraryAssetID else { return nil }
        return photoLibraryAssets.firstIndex {
            $0.localIdentifier == selectedPhotoLibraryAssetID
        }
    }

    private func showAdjacentMedia(offset: Int) {
        guard let selectedPhotoLibraryIndex else { return }
        let newIndex = selectedPhotoLibraryIndex + offset
        guard photoLibraryAssets.indices.contains(newIndex) else { return }
        player?.pause()
        isPlaying = false
        loadPhotoLibraryAsset(photoLibraryAssets[newIndex])
    }

    private func hitTarget(at position: CGPoint) -> MediaSurfaceHitTarget? {
        if isShowingPhotoLibrary {
            if let sidebarTarget = MediaSurfaceInteractionLayout.sidebarTarget(at: position) {
                return sidebarTarget
            }
            return photoLibraryAsset(at: position).map {
                .asset($0.localIdentifier)
            }
        }
        if isVideo {
            return MediaSurfaceInteractionLayout.videoViewerTarget(at: position)
        }
        return MediaSurfaceInteractionLayout.photoViewerTarget(at: position)
    }

    private func perform(_ target: MediaSurfaceHitTarget) {
        switch target {
        case .filter(let filter):
            setPhotoLibraryFilter(filter)
        case .files:
            requestFileImport()
        case .asset(let identifier):
            openPhotoLibraryAsset(withIdentifier: identifier)
        case .previous:
            showPreviousMedia()
        case .next:
            showNextMedia()
        case .close:
            showPhotoLibrary()
        case .togglePlayback:
            togglePlayback()
        case .toggleSpatialVideo:
            toggleSpatialVideo()
        }
    }

    private func loadVideoDuration(from asset: AVAsset) {
        let generation = mediaGeneration
        Task { [weak self] in
            let duration = try? await asset.load(.duration)
            guard let self,
                  generation == mediaGeneration,
                  let seconds = duration?.seconds,
                  seconds.isFinite else { return }
            videoDuration = max(0, seconds)
        }
    }

    private func loadVideoFrameRotation(from asset: AVAsset) {
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform),
                  let self,
                  player?.currentItem?.asset === asset else { return }
            videoFrameRotation = VideoFrameRotation(preferredTransform: transform)
        }
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
        ZStack {
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
                    SDRVideoRendererView(
                        player: player,
                        rotation: session.videoFrameRotation
                    )
                }
            } else {
                GalleryLibraryView(session: session)
            }

            if !session.isShowingPhotoLibrary {
                MediaViewerControlsOverlay(session: session)
                    .zIndex(1)
            }

            if let message = session.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.88), in: Capsule())
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            session.requestPhotoLibraryAccess()
        }
    }
}

private struct GalleryLibraryView: View {
    let session: MediaSession

    var body: some View {
        GeometryReader { proxy in
            let proposedSidebarWidth = proxy.size.width * MediaSurfaceInteractionLayout.sidebarWidth
            let usesCompactSidebar = proposedSidebarWidth < 150
            let sidebarWidth = usesCompactSidebar ? min(72, proxy.size.width * 0.24) : proposedSidebarWidth

            HStack(spacing: 0) {
                MediaLibrarySidebar(
                    session: session,
                    isCompact: usesCompactSidebar
                )
                .frame(width: sidebarWidth)

                PhotoLibraryGridView(session: session)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 1)
                    .offset(x: sidebarWidth)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
    }
}

private struct MediaLibrarySidebar: View {
    let session: MediaSession
    let isCompact: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if isCompact {
                        Image(systemName: "photo.stack")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Gallery", systemImage: "photo.stack")
                                .font(.headline)
                                .lineLimit(1)
                            Text("Filter media")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, isCompact ? 0 : 16)
                .frame(
                    maxWidth: .infinity,
                    minHeight: isCompact
                        ? 64
                        : proxy.size.height * MediaSurfaceInteractionLayout.sidebarHeaderHeight,
                    alignment: isCompact ? .center : .leading
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Gallery filters")

                ForEach(MediaLibraryFilter.allCases) { filter in
                    sidebarButton(
                        title: filter.title,
                        systemImage: filter.systemImage,
                        isSelected: session.photoLibraryFilter == filter
                    ) {
                        session.setPhotoLibraryFilter(filter)
                    }
                    .frame(
                        height: isCompact
                            ? 58
                            : proxy.size.height * MediaSurfaceInteractionLayout.sidebarRowHeight
                    )
                }

                sidebarButton(title: "Files", systemImage: "folder", isSelected: false) {
                    session.requestFileImport()
                }
                .frame(
                    height: isCompact
                        ? 58
                        : proxy.size.height * MediaSurfaceInteractionLayout.sidebarRowHeight
                )

                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.10, blue: 0.12),
                    Color(red: 0.055, green: 0.06, blue: 0.075),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func sidebarButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isCompact {
                    Image(systemName: systemImage)
                        .font(.title3.weight(isSelected ? .semibold : .regular))
                } else {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                .padding(.horizontal, isCompact ? 0 : 16)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: isCompact ? .center : .leading
                )
                .background(isSelected ? Color.cyan.opacity(0.18) : Color.clear)
                .overlay(alignment: .leading) {
                    if isSelected {
                        Capsule()
                            .fill(.cyan)
                            .frame(width: 3)
                            .padding(.vertical, 10)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MediaViewerControlsOverlay: View {
    let session: MediaSession

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if session.isVideo {
                        videoControls
                    } else {
                        photoControls
                    }
                }
                .frame(height: proxy.size.height * (1 - MediaSurfaceInteractionLayout.viewerControlsTop))
                .background(.black.opacity(0.72))
                .overlay(alignment: .top) {
                    Divider().overlay(.white.opacity(0.18))
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var photoControls: some View {
        HStack(spacing: 0) {
            viewerButton("Previous", systemImage: "chevron.left") {
                session.showPreviousMedia()
            }
            .disabled(!session.canShowPreviousMedia)

            viewerButton("Next", systemImage: "chevron.right") {
                session.showNextMedia()
            }
            .disabled(!session.canShowNextMedia)

            viewerButton("Close", systemImage: "xmark") {
                session.showPhotoLibrary()
            }
        }
    }

    private var videoControls: some View {
        HStack(spacing: 0) {
            viewerButton(
                session.isPlaying ? "Pause" : "Play",
                systemImage: session.isPlaying ? "pause.fill" : "play.fill"
            ) {
                session.togglePlayback()
            }

            Label(session.formattedVideoDuration, systemImage: "clock")
                .font(.subheadline.monospacedDigit().weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Video duration")

            viewerButton(
                "Spatial Video",
                systemImage: session.presentationMode == .generatedStereo
                    ? "view.3d"
                    : "rectangle.on.rectangle"
            ) {
                session.toggleSpatialVideo()
            }
            .foregroundStyle(session.presentationMode == .generatedStereo ? .cyan : .white)

            viewerButton("Close", systemImage: "xmark") {
                session.showPhotoLibrary()
            }
        }
    }

    private func viewerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PhotoLibraryGridView: View {
    let session: MediaSession
    @State private var consumedDragRows = 0

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

            VStack(spacing: 0) {
                ForEach(0 ..< layout.rowCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0 ..< layout.columnCount, id: \.self) { column in
                            let index = row * layout.columnCount + column
                            Group {
                                if visibleAssets.indices.contains(index) {
                                    let asset = visibleAssets[index]
                                    Button {
                                        session.openPhotoLibraryAsset(
                                            withIdentifier: asset.localIdentifier
                                        )
                                    } label: {
                                        PhotoLibraryThumbnailView(
                                            asset: asset,
                                            image: session.thumbnail(for: asset)
                                        )
                                        .overlay {
                                            if session.pendingPhotoLibraryAssetID == asset.localIdentifier {
                                                Color.black.opacity(0.42)
                                                ProgressView()
                                                    .tint(.white)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .task(id: asset.localIdentifier) {
                                        session.requestThumbnail(
                                            for: asset,
                                            targetSize: layout.thumbnailTargetSize
                                        )
                                    }
                                } else {
                                    Color.clear
                                }
                            }
                            .padding(layout.spacing / 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topTrailing) {
                Text("\(session.photoLibraryAssets.count) items")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let requestedRows = dragRows(for: value.translation.height)
                        let rowDelta = requestedRows - consumedDragRows
                        guard rowDelta != 0 else { return }
                        session.scrollPhotoLibrary(byRows: rowDelta)
                        consumedDragRows = requestedRows
                    }
                    .onEnded { value in
                        let predictedRows = dragRows(for: value.predictedEndTranslation.height)
                        let extraRows = max(-3, min(3, predictedRows - consumedDragRows))
                        session.scrollPhotoLibrary(byRows: extraRows)
                        consumedDragRows = 0
                    }
            )
        }
        .clipped()
    }

    private func dragRows(for verticalTranslation: CGFloat) -> Int {
        Int((-verticalTranslation / 72).rounded(.towardZero))
    }
}

private extension MediaLibraryFilter {
    var emptyTitle: String {
        switch self {
        case .all: "No photos or videos"
        case .photos: "No photos"
        case .videos: "No videos"
        case .spatial: "No spatial media"
        }
    }

    var emptyDescription: String {
        switch self {
        case .all: "Your photo library is empty."
        case .photos: "There are no photos matching this filter."
        case .videos: "There are no videos matching this filter."
        case .spatial: "There are no spatial photos or videos in your library."
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

            if asset.mediaSubtypes.contains(.spatialMedia) {
                Label("Spatial", systemImage: "view.3d")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.cyan.opacity(0.78), in: Capsule())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
