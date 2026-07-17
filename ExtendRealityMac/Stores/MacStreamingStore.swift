import Observation
import ScreenCaptureKit

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
            let result = try await capture.availableDisplays()
            displays = result.0
            systemDisplays = result.1
            selectedDisplayIDs.formIntersection(Set(displays.map(\.id)))
            if selectedDisplayIDs.isEmpty, let first = displays.first {
                selectedDisplayIDs = [first.id]
            }
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
        let selected = displays.compactMap { display in
            selectedDisplayIDs.contains(display.id) ? systemDisplays[display.id] : nil
        }
        do {
            server.updateMetadata(layout: layout, displays: selectedDisplays)
            try server.start()
            try await capture.start(layout: layout, displays: selected)
            state = .capturing
        } catch {
            server.stop()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        await capture.stop()
        server.stop()
        state = displays.isEmpty ? .idle : .ready
    }

    private func publishCurrentFrames() {
        server.publish(frames: frames, composite: compositeFrame, layout: layout)
    }
}
