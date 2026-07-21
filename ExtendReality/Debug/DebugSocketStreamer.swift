@preconcurrency import ARKit
@preconcurrency import CoreMotion
import Foundation

/// Streams a debug-only spatial snapshot to the browser relay when the
/// `-debugSocketURL` launch argument is present. The production app remains
/// completely inactive when that UserDefaults value is missing.
@MainActor
final class DebugSocketStreamer: NSObject, ARSessionDelegate {
    private static let targetUpdateRate = 60.0
    private static let snapshotInterval: Duration = .nanoseconds(16_666_667)

    private struct PhoneMotion {
        var orientation = HeadPose.identity
        var acceleration = CMAcceleration()
        var gravity = CMAcceleration()
        var rotationRate = CMRotationRate()
    }

    private let workspace: WorkspaceStore
    private let headPose: HeadPoseController
    private let watchRemote: WatchRemoteController
    private let motionManager = CMMotionManager()
    private let arSession = ARSession()
    private var phoneMotion = PhoneMotion()
    private var phoneWorldPosition = SIMD3<Double>(0.86, -0.42, 0.24)
    private var arReferencePosition: SIMD3<Double>?
    private var arTrackingState = "unavailable"
    private var socket: URLSessionWebSocketTask?
    private var streamTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(
        workspace: WorkspaceStore,
        headPose: HeadPoseController,
        watchRemote: WatchRemoteController
    ) {
        self.workspace = workspace
        self.headPose = headPose
        self.watchRemote = watchRemote
        super.init()

        guard let rawURL = UserDefaults.standard.string(forKey: "debugSocketURL"),
              let url = URL(string: rawURL),
              url.scheme == "ws" || url.scheme == "wss" else { return }

        startPhoneMotion()
        startPhoneWorldTracking()
        connect(to: url)
    }

    private func startPhoneWorldTracking() {
        guard ARWorldTrackingConfiguration.isSupported else {
            arTrackingState = "unsupported"
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        arSession.delegate = self
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        arTrackingState = "initializing"
    }

    private func startPhoneMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / Self.targetUpdateRate
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            MainActor.assumeIsolated {
                self?.consume(motion)
            }
        }
    }

    private func consume(_ motion: CMDeviceMotion?) {
        guard let motion else { return }
        let radiansToDegrees = 180.0 / Double.pi
        phoneMotion.orientation = HeadPose(
            yaw: motion.attitude.yaw * radiansToDegrees,
            pitch: motion.attitude.pitch * radiansToDegrees,
            roll: motion.attitude.roll * radiansToDegrees,
            timestamp: motion.timestamp
        )
        phoneMotion.acceleration = motion.userAcceleration
        phoneMotion.gravity = motion.gravity
        phoneMotion.rotationRate = motion.rotationRate
    }

    private func connect(to url: URL) {
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()

        receiveTask = Task { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    _ = try await socket.receive()
                } catch {
                    break
                }
            }
            self?.streamTask?.cancel()
        }

        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendSnapshot()
                try? await Task.sleep(for: Self.snapshotInterval)
            }
        }
    }

    private func sendSnapshot() async {
        guard let socket else { return }
        let payload = snapshotPayload
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else { return }
        do {
            try await socket.send(.string(string))
        } catch {
            streamTask?.cancel()
        }
    }

    private var snapshotPayload: [String: Any] {
        [
            "type": "snapshot",
            "timestamp": Date().timeIntervalSince1970 * 1_000,
            "device": [
                "id": "extend-reality-iphone",
                "name": ProcessInfo.processInfo.hostName,
                "platform": "iOS"
            ],
            "sensors": [
                "head": poseDictionary(headPose.pose).merging([
                    "source": "AirPods",
                    "connected": headPose.isTracking,
                    "status": headPose.statusText
                ]) { _, new in new },
                "phone": poseDictionary(phoneMotion.orientation).merging([
                    "acceleration": vectorDictionary(phoneMotion.acceleration),
                    "gravity": vectorDictionary(phoneMotion.gravity),
                    "rotationRate": rotationDictionary(phoneMotion.rotationRate),
                    "positionTracking": arTrackingState
                ]) { _, new in new },
                "watch": [
                    "connected": watchRemote.isWatchReachable,
                    "status": watchRemote.statusText
                ]
            ],
            "devices": [
                "head": ["position": ["x": 0, "y": 0.35, "z": 0]],
                "phone": [
                    "position": [
                        "x": phoneWorldPosition.x,
                        "y": phoneWorldPosition.y,
                        "z": phoneWorldPosition.z
                    ],
                    "positionSource": "ARKit",
                    "tracking": arTrackingState
                ],
                "watch": ["position": ["x": -0.72, "y": -0.4, "z": 0.15]]
            ],
            "windows": workspace.windows.map(windowDictionary)
        ]
    }

    private func poseDictionary(_ pose: HeadPose) -> [String: Any] {
        [
            "orientation": [
                "yaw": pose.yaw,
                "pitch": pose.pitch,
                "roll": pose.roll
            ],
            "sensorTimestamp": pose.timestamp
        ]
    }

    private func vectorDictionary(_ value: CMAcceleration) -> [String: Double] {
        ["x": value.x, "y": value.y, "z": value.z]
    }

    private func rotationDictionary(_ value: CMRotationRate) -> [String: Double] {
        ["x": value.x, "y": value.y, "z": value.z]
    }

    private func windowDictionary(_ window: WorkspaceWindow) -> [String: Any] {
        [
            "id": window.id.uuidString,
            "title": window.title,
            "kind": window.kind.rawValue,
            "transform": [
                "yaw": window.transform.yaw,
                "pitch": window.transform.pitch,
                "virtualDistance": window.transform.virtualDistance,
                "width": window.transform.width,
                "height": window.transform.height
            ],
            "zIndex": window.zIndex,
            "isMinimized": window.isMinimized,
            "focused": workspace.activeWindowID == window.id
        ]
    }
}

extension DebugSocketStreamer {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let column = frame.camera.transform.columns.3
        let x = Double(column.x)
        let y = Double(column.y)
        let z = Double(column.z)
        let trackingState: String
        switch frame.camera.trackingState {
        case .normal:
            trackingState = "normal"
        case .notAvailable:
            trackingState = "notAvailable"
        case .limited(let reason):
            trackingState = "limited:\(String(describing: reason))"
        }
        Task { @MainActor [weak self] in
            self?.consumeARPosition(x: x, y: y, z: z, trackingState: trackingState)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        let message = "error:\(error.localizedDescription)"
        Task { @MainActor [weak self] in
            self?.arTrackingState = message
        }
    }

    private func consumeARPosition(
        x: Double,
        y: Double,
        z: Double,
        trackingState: String
    ) {
        let position = SIMD3<Double>(x, y, z)
        if arReferencePosition == nil {
            arReferencePosition = position
        }
        guard let arReferencePosition else { return }
        let delta = position - arReferencePosition
        phoneWorldPosition = SIMD3<Double>(0.86, -0.42, 0.24) + delta
        arTrackingState = trackingState
    }
}
