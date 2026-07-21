import Observation
import ScreenCaptureKit

private enum MacStreamingError: LocalizedError {
    case noDisplays
    case applicationUnavailable
    case directModeActive

    var errorDescription: String? {
        switch self {
        case .noDisplays: "No Mac displays are available for streaming."
        case .applicationUnavailable: "The selected application is no longer available to share."
        case .directModeActive: "Direct Mode is active. Stop it before starting Wi-Fi Sharing."
        }
    }
}

@MainActor
@Observable
final class MacStreamingStore {
    var acceptsRemoteStarts = true
    var layout: StreamLayout = .single {
        didSet {
            if layout == .single, selectedDisplayIDs.count > 1 {
                selectedDisplayIDs = Set(selectedDisplayIDs.prefix(1))
            }
        }
    }
    var displays: [CaptureDisplay] = []
    var selectedDisplayIDs: Set<CGDirectDisplayID> = []
    var state: CaptureState = .idle
    var frames: [CGDirectDisplayID: CGImage] = [:]
    var compositeFrame: CGImage?
    var streamAddress: URL?
    var connectedViewerCount = 0
    var connectedAudioPlaybackCount = 0
    var connectedMicrophoneCount = 0

    private let capture = ScreenCaptureCoordinator()
    private let server = FrameStreamingServer()
    private let microphoneMonitor = RemoteMicrophoneMonitor()
    private var systemDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    private var systemApplications: [String: CaptureApplicationTarget] = [:]
    private var activeLayout: StreamLayout = .single

    init() {
        capture.onFramesChanged = { [weak self] frames in
            self?.frames = frames
            self?.publishCurrentFrames()
        }
        capture.onCompositeFrameChanged = { [weak self] frame in
            self?.compositeFrame = frame
            self?.publishCurrentFrames()
        }
        capture.onAudioPCM = { [weak self] data in
            self?.server.publishAudio(data)
        }
        capture.onFailure = { [weak self] message in
            self?.state = .failed(message)
        }
        server.onAddressChanged = { [weak self] address in
            self?.streamAddress = address
        }
        server.onViewerCountChanged = { [weak self] count in
            self?.connectedViewerCount = count
        }
        server.onAudioPlaybackClientCountChanged = { [weak self] count in
            self?.connectedAudioPlaybackCount = count
        }
        server.onMicrophoneClientCountChanged = { [weak self] count in
            self?.connectedMicrophoneCount = count
            if count == 0 {
                self?.microphoneMonitor.stop()
            }
        }
        server.onMicrophonePCM = { [weak self] data in
            self?.microphoneMonitor.consume(data)
        }
        server.onFailure = { [weak self] message in
            self?.state = .failed(message)
        }
        server.onApplicationsRequested = { [weak self] in
            guard let self else { return [] }
            return try await self.loadApplications()
        }
        server.onStartRequested = { [weak self] request in
            guard let self else { return }
            try await self.startRemotely(request)
        }
        do {
            try server.start()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var selectedDisplays: [CaptureDisplay] {
        displays.filter { selectedDisplayIDs.contains($0.id) }
    }

    var canStart: Bool {
        !selectedDisplayIDs.isEmpty && state != .capturing && state != .loading
    }

    func refreshDisplays() async {
        state = .loading
        do {
            try await loadDisplays()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func select(_ displayID: CGDirectDisplayID) {
        if layout == .single {
            selectedDisplayIDs = [displayID]
        } else if selectedDisplayIDs.contains(displayID) {
            guard selectedDisplayIDs.count > 1 else { return }
            selectedDisplayIDs.remove(displayID)
        } else {
            selectedDisplayIDs.insert(displayID)
        }
    }

    func start() async {
        do {
            try await startCapture()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        await capture.stop()
        server.endAudioSession()
        microphoneMonitor.stop()
        frames = [:]
        compositeFrame = nil
        state = displays.isEmpty ? .idle : .ready
    }

    private func startRemotely(_ request: RemoteStreamStartRequest) async throws {
        guard acceptsRemoteStarts else {
            throw MacStreamingError.directModeActive
        }
        if let applicationID = request.applicationID {
            var target = systemApplications[applicationID]
            if target == nil {
                _ = try await loadApplications()
                target = systemApplications[applicationID]
            }
            guard let target else {
                throw MacStreamingError.applicationUnavailable
            }
            try await startApplicationCapture(target)
            return
        }

        layout = request.layout
        if displays.isEmpty {
            state = .loading
            try await loadDisplays()
        }
        try await startCapture(usesVirtualCursor: request.usesVirtualCursor)
    }

    private func loadDisplays() async throws {
        let result = try await capture.availableDisplays()
        displays = result.0
        systemDisplays = result.1
        selectedDisplayIDs.formIntersection(Set(displays.map(\.id)))
        if selectedDisplayIDs.isEmpty, let first = displays.first {
            selectedDisplayIDs = [first.id]
        }
    }

    private func loadApplications() async throws -> [RemoteShareableApplication] {
        let result = try await capture.availableApplications()
        systemApplications = result.1
        return result.0.map(\.remoteRepresentation)
    }

    private func startCapture(usesVirtualCursor: Bool = false) async throws {
        if state == .capturing {
            await capture.stop()
            server.endAudioSession()
            microphoneMonitor.stop()
        }
        let selected = displays.compactMap { display in
            selectedDisplayIDs.contains(display.id) ? systemDisplays[display.id] : nil
        }
        guard !selected.isEmpty else {
            throw MacStreamingError.noDisplays
        }

        frames = [:]
        compositeFrame = nil
        activeLayout = layout
        server.updateMetadata(
            layout: layout,
            displays: selectedDisplays,
            usesVirtualCursor: usesVirtualCursor,
            isApplicationCapture: false
        )
        try await capture.start(
            layout: layout,
            displays: selected,
            showsCursor: !usesVirtualCursor
        )
        state = .capturing
    }

    private func startApplicationCapture(_ target: CaptureApplicationTarget) async throws {
        if state == .capturing {
            await capture.stop()
            server.endAudioSession()
            microphoneMonitor.stop()
        }

        let application = target.descriptor
        let streamDisplay = CaptureDisplay(
            id: application.displayID,
            name: application.name,
            width: application.width,
            height: application.height
        )
        frames = [:]
        compositeFrame = nil
        activeLayout = .single
        server.updateMetadata(
            layout: .single,
            displays: [streamDisplay],
            usesVirtualCursor: false,
            isApplicationCapture: true
        )
        try await capture.start(application: target, showsCursor: true)
        state = .capturing
    }

    private func publishCurrentFrames() {
        server.publish(frames: frames, composite: compositeFrame, layout: activeLayout)
    }
}
