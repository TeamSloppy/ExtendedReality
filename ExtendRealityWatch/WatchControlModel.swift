@preconcurrency import CoreMotion
import Foundation
import Observation
import WatchConnectivity
import WatchKit

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
@Observable
final class WatchControlModel: NSObject {
    private(set) var isReachable = false
    private(set) var isPointerActive = false
    private(set) var motionAvailable = false
    private(set) var snapshot = WatchWorkspaceSnapshot(
        activeWindowID: nil,
        windows: [],
        trackingStatus: "Waiting for iPhone",
        isTracking: false
    )
    var sensitivity = 1.0
    var invertVertical = false

    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var accumulatedX = 0.0
    @ObservationIgnored private var accumulatedY = 0.0
    @ObservationIgnored private var lastSentAt = 0.0
    @ObservationIgnored private var isPreview = false

    override init() {
        super.init()
        motionAvailable = motionManager.isDeviceMotionAvailable

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        apply(session.receivedApplicationContext)
    }

#if DEBUG
    init(previewSnapshot: WatchWorkspaceSnapshot) {
        super.init()
        snapshot = previewSnapshot
        isReachable = true
        motionAvailable = true
        isPreview = true
    }
#endif

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }

    var activeWindow: WatchWindowSummary? {
        snapshot.windows.first(where: { $0.id == snapshot.activeWindowID })
    }

    var connectionText: String {
        isReachable ? "iPhone connected" : "Open iPhone app"
    }

    var isVoiceAssistantActive: Bool {
        snapshot.voiceAssistantPhase != "idle" && snapshot.voiceAssistantPhase != "cancelled"
    }

    func togglePointer() {
        isPointerActive ? stopPointer() : startPointer()
    }

    func startPointer() {
        guard motionManager.isDeviceMotionAvailable else {
            motionAvailable = false
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }
        motionAvailable = true
        accumulatedX = 0
        accumulatedY = 0
        lastSentAt = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 40.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            MainActor.assumeIsolated {
                self?.consume(motion)
            }
        }
        isPointerActive = true
    }

    func stopPointer() {
        motionManager.stopDeviceMotionUpdates()
        isPointerActive = false
        accumulatedX = 0
        accumulatedY = 0
    }

    func click() {
        send(.click)
        WKInterfaceDevice.current().play(.click)
    }

    func scroll(crownDelta: Double) {
        guard crownDelta != 0 else { return }
        send(.scroll(delta: crownDelta * 0.018))
    }

    func recenter() {
        accumulatedX = 0
        accumulatedY = 0
        send(.recenter, expectsState: true)
        WKInterfaceDevice.current().play(.directionUp)
    }

    func focus(_ window: WatchWindowSummary) {
        send(.focusWindow(id: window.id), expectsState: true)
    }

    func open(kind: String) {
        send(.openWindow(kind: kind), expectsState: true)
    }

    func minimize(_ window: WatchWindowSummary) {
        send(.minimizeWindow(id: window.id), expectsState: true)
    }

    func close(_ window: WatchWindowSummary) {
        send(.closeWindow(id: window.id), expectsState: true)
    }

    func back() {
        send(.back)
    }

    func toggleVoiceAssistant() {
        send(.toggleVoiceAssistant, expectsState: true)
        WKInterfaceDevice.current().play(.click)
    }

    func refresh() {
        send(.requestState, expectsState: true)
    }

    private func consume(_ motion: CMDeviceMotion?) {
        guard let motion, isPointerActive else { return }
        let deadZone = 0.07
        let horizontalRate = applyDeadZone(motion.rotationRate.y, deadZone: deadZone)
        let verticalRate = applyDeadZone(motion.rotationRate.x, deadZone: deadZone)
        let interval = motionManager.deviceMotionUpdateInterval
        let gain = 0.15 * sensitivity

        accumulatedX += horizontalRate * interval * gain
        accumulatedY += verticalRate * interval * gain * (invertVertical ? -1 : 1)

        guard motion.timestamp - lastSentAt >= 0.05 else { return }
        let x = accumulatedX
        let y = accumulatedY
        accumulatedX = 0
        accumulatedY = 0
        lastSentAt = motion.timestamp

        if abs(x) > 0.0002 || abs(y) > 0.0002 {
            send(.pointerDelta(x: x, y: y))
        }
    }

    private func applyDeadZone(_ value: Double, deadZone: Double) -> Double {
        guard abs(value) > deadZone else { return 0 }
        return value - deadZone * (value < 0 ? -1 : 1)
    }

    private func send(_ command: WatchControlCommand, expectsState: Bool = false) {
        guard !isPreview else { return }
        guard let session, session.activationState == .activated, session.isReachable else {
            isReachable = false
            return
        }

        let errorHandler = Self.makeErrorHandler(for: self)
        if expectsState {
            session.sendMessage(
                command.dictionary,
                replyHandler: Self.makeReplyHandler(for: self),
                errorHandler: errorHandler
            )
        } else {
            session.sendMessage(command.dictionary, replyHandler: nil, errorHandler: errorHandler)
        }
    }

    // WatchConnectivity invokes these handlers on its own operation queue. Build
    // them outside MainActor isolation, then explicitly hop to the UI actor.
    private nonisolated static func makeReplyHandler(
        for model: WatchControlModel
    ) -> ([String: Any]) -> Void {
        { [weak model] response in
            guard let snapshot = WatchWorkspaceSnapshot(dictionary: response) else { return }
            Task { @MainActor [weak model, snapshot] in
                model?.snapshot = snapshot
            }
        }
    }

    private nonisolated static func makeErrorHandler(
        for model: WatchControlModel
    ) -> (any Error) -> Void {
        { [weak model] _ in
            Task { @MainActor [weak model] in
                model?.isReachable = false
            }
        }
    }

    private func apply(_ dictionary: [String: Any]) {
        guard let snapshot = WatchWorkspaceSnapshot(dictionary: dictionary) else { return }
        self.snapshot = snapshot
    }
}

#if DEBUG
@MainActor
extension WatchControlModel {
    static func preview() -> WatchControlModel {
        let browserID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let galleryID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        return WatchControlModel(
            previewSnapshot: WatchWorkspaceSnapshot(
                activeWindowID: browserID,
                windows: [
                    WatchWindowSummary(
                        id: browserID,
                        title: "Browser",
                        kind: "browser",
                        isMinimized: false
                    ),
                    WatchWindowSummary(
                        id: galleryID,
                        title: "Gallery",
                        kind: "gallery",
                        isMinimized: true
                    ),
                ],
                trackingStatus: "AirPods 3DoF active",
                isTracking: true
            )
        )
    }
}
#endif

extension WatchControlModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachable = session.isReachable
        let context = UncheckedSendable(value: session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = reachable
            self.apply(context.value)
            if activationState == .activated { self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
            if reachable { self?.refresh() }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let context = UncheckedSendable(value: applicationContext)
        Task { @MainActor [weak self] in self?.apply(context.value) }
    }
}
