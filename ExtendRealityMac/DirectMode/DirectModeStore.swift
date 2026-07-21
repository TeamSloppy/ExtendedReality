import AppKit
import CoreVideo
import Observation
import SwiftData

enum MacRuntimeMode: String, CaseIterable, Identifiable, Sendable {
    case sharing
    case direct

    var id: String { rawValue }
    var title: String { self == .sharing ? "Wi-Fi Sharing" : "Direct Mode" }
}

enum MacRuntimeConflictPolicy {
    static func permitsRemoteStart(in mode: MacRuntimeMode) -> Bool {
        mode == .sharing
    }
}

enum DirectModeState: Equatable {
    case idle
    case loading
    case ready
    case running
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Not configured"
        case .loading: "Loading sources…"
        case .ready: "Ready"
        case .running: "Direct Mode active"
        case .failed: "Needs attention"
        }
    }
}

struct DirectOutputDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let uuid: UUID
    let name: String
    let pixelSize: CGSize
    let isMain: Bool
    let isExtended: Bool
    let isMirrored: Bool
    let looksLikeXREAL: Bool

    var isStandard1080p: Bool { pixelSize == CGSize(width: 1_920, height: 1_080) }
    var isValidDirectOutput: Bool { isExtended && !isMirrored && isStandard1080p }
    var detail: String {
        var parts = ["\(Int(pixelSize.width))×\(Int(pixelSize.height))"]
        if isMain { parts.append("main") }
        if isMirrored { parts.append("mirrored") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class DirectModeStore {
    private(set) var state: DirectModeState = .idle
    private(set) var sources: [DirectCaptureSource] = []
    private(set) var outputDisplays: [DirectOutputDisplay] = []
    var selectedOutputDisplayID: CGDirectDisplayID?
    private(set) var frames: [MacCaptureSourceReference: CVPixelBuffer] = [:]
    private(set) var virtualCursor = CGPoint(x: 0.5, y: 0.5)
    private(set) var windowFrames: [UUID: CGRect] = [:]
    private(set) var canvasSize: CGSize = CGSize(width: 1_920, height: 1_080)
    private(set) var inputStatus = "Pointer released"

    let workspace: WorkspaceStore
    let headPose: HeadPoseController

    @ObservationIgnored private let modelContainer: ModelContainer
    @ObservationIgnored private let capture = DirectCaptureCoordinator()
    @ObservationIgnored private let poseProvider: PreferredHeadPoseProvider
    @ObservationIgnored private let windowController = DirectDisplayWindowController()
    @ObservationIgnored private lazy var inputController = SpatialPointerController(store: self)
    @ObservationIgnored private var catalogTask: Task<Void, Never>?

    var onRunningChanged: ((Bool) -> Void)?

    init(storesDataInMemory: Bool = false) {
        let schema = Schema([WorkspaceSnapshot.self])
        let testEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let configuration = ModelConfiguration(
            "DirectSpatialWorkspace",
            schema: schema,
            isStoredInMemoryOnly: storesDataInMemory || testEnvironment
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            modelContainer = try! ModelContainer(for: schema, configurations: [fallback])
        }
        workspace = WorkspaceStore(persistence: WorkspacePersistence(container: modelContainer))
        poseProvider = PreferredHeadPoseProvider(
            primary: XREALUSBPoseProvider(),
            fallback: MacAirPodsPoseProvider()
        )
        headPose = HeadPoseController(provider: poseProvider)

        capture.onFrame = { [weak self] reference, pixelBuffer in
            self?.frames[reference] = pixelBuffer
        }
        capture.onFailure = { [weak self] message in
            self?.state = .failed(message)
        }
        windowController.onOutputUnavailable = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.stop(reason: "Output display disconnected")
            }
        }
    }

    var selectedReferences: Set<MacCaptureSourceReference> {
        Set(workspace.windows.compactMap { window in
            guard case .macCapture(let reference) = window.source else { return nil }
            return reference
        })
    }

    var availableSelectedReferences: Set<MacCaptureSourceReference> {
        Set(selectedReferences.filter { source(for: $0) != nil })
    }

    var outputConfigurationIssue: String? {
        guard let output = selectedOutputDisplay else {
            if outputDisplays.count < 2 {
                return "Connect the glasses as an extended display, then refresh."
            }
            return "Choose the glasses output display."
        }
        guard output.isExtended else {
            return "The glasses must be connected as an extended display."
        }
        guard !output.isMirrored else {
            return "Turn off display mirroring for \(output.name)."
        }
        guard output.isStandard1080p else {
            return "Set \(output.name) to 1920×1080 in System Settings → Displays."
        }
        return nil
    }

    var configurationIssue: String? {
        if let outputConfigurationIssue { return outputConfigurationIssue }
        guard !selectedReferences.isEmpty else {
            return "Select at least one Mac display or application."
        }
        guard !availableSelectedReferences.isEmpty else {
            return "The selected sources are currently unavailable."
        }
        return nil
    }

    var statusTitle: String {
        switch state {
        case .running: "Direct Mode active"
        case .loading: "Loading…"
        case .failed: "Needs attention"
        case .idle, .ready: configurationIssue == nil ? "Ready" : "Setup required"
        }
    }

    var canStart: Bool {
        state != .running && state != .loading && configurationIssue == nil
    }

    var selectedOutputDisplay: DirectOutputDisplay? {
        outputDisplays.first(where: { $0.id == selectedOutputDisplayID })
    }

    var isPointerCaptured: Bool { inputController.isCapturing }

    func refresh() async {
        poseProvider.activate()
        let wasRunning = state == .running
        if !wasRunning { state = .loading }
        refreshOutputDisplays()
        do {
            sources = try await capture.refresh(excludingOutputDisplayID: selectedOutputDisplayID)
            removeOutputDisplayFromWorkspace()
            state = wasRunning ? .running : .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func selectOutput(_ id: CGDirectDisplayID?) {
        guard state != .running else { return }
        selectedOutputDisplayID = id
        removeOutputDisplayFromWorkspace()
        Task { await refresh() }
    }

    func setSource(_ source: DirectCaptureSource, selected: Bool) {
        let existing = workspace.windows.first(where: { $0.source == .macCapture(source.reference) })
        if selected, existing == nil {
            workspace.addWindow(
                title: source.title,
                source: .macCapture(source.reference),
                transform: .macStream,
                contentAspectRatio: source.aspectRatio
            )
        } else if !selected, let existing {
            workspace.close(existing.id)
            frames.removeValue(forKey: source.reference)
        }
        restartCaptureIfRunning()
    }

    func removeWindow(_ id: UUID) {
        guard let window = workspace.windows.first(where: { $0.id == id }) else { return }
        workspace.close(id)
        if case .macCapture(let reference) = window.source {
            frames.removeValue(forKey: reference)
        }
        restartCaptureIfRunning()
    }

    func isSelected(_ source: DirectCaptureSource) -> Bool {
        selectedReferences.contains(source.reference)
    }

    func source(for reference: MacCaptureSourceReference) -> DirectCaptureSource? {
        sources.first(where: { $0.reference == reference })
    }

    func start() async {
        if let configurationIssue {
            state = .failed(configurationIssue)
            return
        }
        guard let output = selectedOutputDisplay,
              let screen = NSScreen.screens.first(where: { DirectCaptureCoordinator.displayID(for: $0) == output.id }) else {
            state = .failed("The selected output display is no longer connected.")
            return
        }
        state = .loading
        do {
            try await capture.start(references: availableSelectedReferences)
            for window in workspace.windows where window.isMinimized { workspace.focus(window.id) }
            windowController.show(on: screen, store: self)
            state = .running
            onRunningChanged?(true)
            startCatalogRefresh()
        } catch {
            await capture.stop()
            state = .failed(error.localizedDescription)
        }
    }

    func stop(reason: String? = nil) async {
        catalogTask?.cancel()
        catalogTask = nil
        inputController.stop()
        await capture.stop()
        frames.removeAll()
        windowController.close()
        onRunningChanged?(false)
        refreshOutputDisplays()
        state = reason.map(DirectModeState.failed) ?? .ready
    }

    func recenter() {
        headPose.recenter()
        workspace.centerActiveWindow(for: .identity)
    }

    func togglePointerCapture() {
        if inputController.isCapturing {
            inputController.stop()
        } else {
            inputController.start()
        }
        inputStatus = inputController.statusText
    }

    func openInputPrivacySettings() {
        inputController.openPrivacySettings()
    }

    func updateCanvas(size: CGSize, windowFrames: [UUID: CGRect]) {
        canvasSize = size
        self.windowFrames = windowFrames
    }

    func moveVirtualCursor(by delta: CGVector) {
        virtualCursor.x = (virtualCursor.x + delta.dx / max(canvasSize.width, 1)).clamped(to: 0 ... 1)
        virtualCursor.y = (virtualCursor.y + delta.dy / max(canvasSize.height, 1)).clamped(to: 0 ... 1)
    }

    func sourcePoint(atCanvasPoint point: CGPoint) -> (DirectCaptureSource, CGPoint)? {
        let windows = workspace.windows
            .filter { !$0.isMinimized }
            .sorted { $0.zIndex > $1.zIndex }
        for window in windows {
            guard let frame = windowFrames[window.id],
                  case .macCapture(let reference) = window.source,
                  let source = source(for: reference) else { continue }
            let surfaceFrame = DirectWindowGeometry.surfaceFrame(in: frame)
            if let mapped = SpatialSourceMapping.globalPoint(
                canvasPoint: point,
                surfaceFrame: surfaceFrame,
                sourceFrame: source.globalFrame,
                sourceAspectRatio: CGFloat(source.aspectRatio),
                rotationRadians: CGFloat(-headPose.pose.roll * .pi / 180)
            ) {
                workspace.focus(window.id)
                return (source, mapped)
            }
        }
        return nil
    }

    private func refreshOutputDisplays() {
        let screens = NSScreen.screens
        let hasExtendedDesktop = screens.count > 1
        outputDisplays = screens.compactMap { screen in
            guard let id = DirectCaptureCoordinator.displayID(for: screen),
                  let uuid = MacDisplayIdentity.uuid(for: id) else { return nil }
            let size = CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
            let name = screen.localizedName
            return DirectOutputDisplay(
                id: id,
                uuid: uuid,
                name: name,
                pixelSize: size,
                isMain: CGDisplayIsMain(id) != 0,
                isExtended: hasExtendedDesktop,
                isMirrored: CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay,
                looksLikeXREAL: name.localizedCaseInsensitiveContains("XREAL")
                    || name.localizedCaseInsensitiveContains("Air")
            )
        }
        if !outputDisplays.contains(where: { $0.id == selectedOutputDisplayID }) {
            selectedOutputDisplayID = outputDisplays.first(where: { $0.looksLikeXREAL && $0.isValidDirectOutput })?.id
                ?? outputDisplays.first(where: \.isValidDirectOutput)?.id
                ?? outputDisplays.first(where: \.looksLikeXREAL)?.id
        }
        removeOutputDisplayFromWorkspace()
    }

    private func removeOutputDisplayFromWorkspace() {
        guard let output = selectedOutputDisplay else { return }
        let outputReference = MacCaptureSourceReference.display(uuid: output.uuid)
        for window in workspace.windows where window.source == .macCapture(outputReference) {
            workspace.close(window.id)
        }
        frames.removeValue(forKey: outputReference)
    }

    private func restartCaptureIfRunning() {
        guard state == .running else { return }
        Task {
            do { try await capture.start(references: selectedReferences) }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    private func startCatalogRefresh() {
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                do {
                    let oldSources = self.sources
                    self.refreshOutputDisplays()
                    guard self.outputDisplays.contains(where: { $0.id == self.selectedOutputDisplayID }) else {
                        await self.stop(reason: "Output display disconnected")
                        return
                    }
                    self.sources = try await self.capture.refresh(
                        excludingOutputDisplayID: self.selectedOutputDisplayID
                    )
                    if self.sources != oldSources {
                        try await self.capture.start(references: self.selectedReferences)
                    }
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}

@MainActor
@Observable
final class MacAppModel {
    var mode: MacRuntimeMode = .sharing {
        didSet {
            guard mode != oldValue else { return }
            sharing.acceptsRemoteStarts = MacRuntimeConflictPolicy.permitsRemoteStart(in: mode)
            Task { await transition(from: oldValue, to: mode) }
        }
    }
    let sharing = MacStreamingStore()
    let direct = DirectModeStore()

    init() {
        direct.onRunningChanged = { [weak self] _ in
            guard let self else { return }
            self.sharing.acceptsRemoteStarts = MacRuntimeConflictPolicy.permitsRemoteStart(in: self.mode)
        }
    }

    private func transition(from oldMode: MacRuntimeMode, to newMode: MacRuntimeMode) async {
        switch oldMode {
        case .sharing: await sharing.stop()
        case .direct: await direct.stop()
        }
        sharing.acceptsRemoteStarts = MacRuntimeConflictPolicy.permitsRemoteStart(in: newMode)
        if newMode == .direct { await direct.refresh() }
    }
}
