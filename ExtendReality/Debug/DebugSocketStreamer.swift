@preconcurrency import CoreMotion
import Foundation

/// Streams a debug-only spatial snapshot to the browser relay when the
/// `-debugSocketURL` launch argument is present. The production app remains
/// completely inactive when that UserDefaults value is missing.
@MainActor
final class DebugSocketStreamer {
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
    private var phoneMotion = PhoneMotion()
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

        guard let rawURL = UserDefaults.standard.string(forKey: "debugSocketURL"),
              let url = URL(string: rawURL),
              url.scheme == "ws" || url.scheme == "wss" else { return }

        startPhoneMotion()
        connect(to: url)
    }

    private func startPhoneMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
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
                try? await Task.sleep(for: .milliseconds(50))
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
                    "rotationRate": rotationDictionary(phoneMotion.rotationRate)
                ]) { _, new in new },
                "watch": [
                    "connected": watchRemote.isWatchReachable,
                    "status": watchRemote.statusText
                ]
            ],
            "devices": [
                "head": ["position": ["x": 0, "y": 0.35, "z": 0]],
                "phone": ["position": ["x": 0.86, "y": -0.42, "z": 0.24]],
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
