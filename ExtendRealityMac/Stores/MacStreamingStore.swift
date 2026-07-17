import Observation
import ScreenCaptureKit

private enum MacStreamingError: LocalizedError {
    case noDisplays

    var errorDescription: String? {
        switch self {
        case .noDisplays: "No Mac displays are available for streaming."
        }
    }
}

@MainActor
@Observable
final class MacStreamingStore {
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

    private let capture = ScreenCaptureCoordinator()
    private let server = FrameStreamingServer()
    private var systemDisplays: [CGDirectDisplayID: SCDisplay] = [:]

    init() {
        capture.onFramesChanged = { [weak self] frames in
            self?.frames = frames
            self?.publishCurrentFrames()
        }
        capture.onCompositeFrameChanged = { [weak self] frame in
            self?.compositeFrame = frame
            self?.publishCurrentFrames()
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
        server.onFailure = { [weak self] message in
            self?.state = .failed(message)
        }
        server.onStartRequested = { [weak self] layout in
            guard let self else { return }
            try await self.startRemotely(layout: layout)
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
        frames = [:]
        compositeFrame = nil
        state = displays.isEmpty ? .idle : .ready
    }

    private func startRemotely(layout requestedLayout: StreamLayout) async throws {
        layout = requestedLayout
        if displays.isEmpty {
            state = .loading
            try await loadDisplays()
        }
        try await startCapture()
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

    private func startCapture() async throws {
        if state == .capturing {
            await capture.stop()
        }
        let selected = displays.compactMap { display in
            selectedDisplayIDs.contains(display.id) ? systemDisplays[display.id] : nil
        }
        guard !selected.isEmpty else {
            throw MacStreamingError.noDisplays
        }

        frames = [:]
        compositeFrame = nil
        server.updateMetadata(layout: layout, displays: selectedDisplays)
        try await capture.start(layout: layout, displays: selected)
        state = .capturing
    }

    private func publishCurrentFrames() {
        server.publish(frames: frames, composite: compositeFrame, layout: layout)
    }
}
