import CoreGraphics
import Foundation
import Observation
import WatchConnectivity

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
@Observable
final class WatchRemoteController: NSObject {
    private(set) var isWatchReachable = false
    private(set) var lastError: String?

    @ObservationIgnored private let workspace: WorkspaceStore
    @ObservationIgnored private let inputRouter: InputRouter
    @ObservationIgnored private let surfaces: SurfaceRegistry
    @ObservationIgnored private let headPose: HeadPoseController
    @ObservationIgnored private let voiceAssistant: VoiceAssistantCoordinator
    @ObservationIgnored private var session: WCSession?

    init(
        workspace: WorkspaceStore,
        inputRouter: InputRouter,
        surfaces: SurfaceRegistry,
        headPose: HeadPoseController,
        voiceAssistant: VoiceAssistantCoordinator,
        activatesSession: Bool = true
    ) {
        self.workspace = workspace
        self.inputRouter = inputRouter
        self.surfaces = surfaces
        self.headPose = headPose
        self.voiceAssistant = voiceAssistant
        super.init()

        guard activatesSession else { return }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    var statusText: String {
        if isWatchReachable { return "Apple Watch connected" }
        if let lastError { return lastError }
        return "Open ExtendReality on Apple Watch"
    }

    func syncState() {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(snapshot.dictionary)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var snapshot: WatchWorkspaceSnapshot {
        WatchWorkspaceSnapshot(
            activeWindowID: workspace.activeWindowID,
            windows: workspace.windows.map {
                WatchWindowSummary(
                    id: $0.id,
                    title: $0.title,
                    kind: $0.kind.rawValue,
                    isMinimized: $0.isMinimized
                )
            },
            trackingStatus: headPose.statusText,
            isTracking: headPose.isTracking,
            voiceAssistantPhase: voiceAssistant.state.phase.rawValue
        )
    }

    private func handle(_ command: WatchControlCommand) {
        switch command {
        case .pointerDelta(let x, let y):
            inputRouter.movePointer(
                delta: CGVector(dx: x, dy: y),
                in: workspace.activeWindowID
            )
        case .scroll(let delta):
            inputRouter.scroll(
                delta: CGVector(dx: 0, dy: delta),
                in: workspace.activeWindowID
            )
        case .click:
            inputRouter.pointerDown(in: workspace.activeWindowID)
            inputRouter.pointerUp(in: workspace.activeWindowID)
        case .recenter:
            workspace.recenter()
            inputRouter.resetCursor()
            headPose.recenter()
        case .focusWindow(let id):
            workspace.focus(id)
        case .openWindow(let rawKind):
            guard let kind = WindowKind(rawValue: rawKind) else { return }
            let window = workspace.addWindow(kind: kind)
            surfaces.prepare(for: [window])
        case .minimizeWindow(let id):
            workspace.toggleMinimize(id)
        case .closeWindow(let id):
            workspace.close(id)
            inputRouter.unregister(windowID: id)
            surfaces.remove(windowID: id)
        case .back:
            inputRouter.back(in: workspace.activeWindowID)
        case .toggleVoiceAssistant:
            voiceAssistant.toggle()
        case .requestState:
            break
        }

        if commandChangesWorkspace(command) {
            syncState()
        }
    }

    private func commandChangesWorkspace(_ command: WatchControlCommand) -> Bool {
        switch command {
        case .focusWindow, .openWindow, .minimizeWindow, .closeWindow, .recenter, .toggleVoiceAssistant, .requestState:
            true
        case .pointerDelta, .scroll, .click, .back:
            false
        }
    }
}

extension WatchRemoteController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachable = session.isReachable
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastError = errorDescription
            self.isWatchReachable = reachable
            self.syncState()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.isWatchReachable = false }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isWatchReachable = reachable
            if reachable { self?.syncState() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchControlCommand(dictionary: message) else { return }
        Task { @MainActor [weak self] in self?.handle(command) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = WatchControlCommand(dictionary: message) else {
            replyHandler(["error": "Invalid command"])
            return
        }
        let reply = UncheckedSendable(value: replyHandler)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handle(command)
            reply.value(self.snapshot.dictionary)
        }
    }
}
