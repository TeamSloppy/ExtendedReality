@preconcurrency import CoreMotion
import Foundation
import Observation

struct HeadPose: Equatable, Sendable {
    var yaw: Double
    var pitch: Double
    var roll: Double
    var timestamp: TimeInterval

    static let identity = HeadPose(yaw: 0, pitch: 0, roll: 0, timestamp: 0)
}

enum HeadPoseAvailability: Equatable, Sendable {
    case available
    case waiting(reason: String)
    case unavailable(reason: String)
}

enum HeadPoseEvent: Equatable, Sendable {
    case availability(HeadPoseAvailability)
    case pose(HeadPose)
}

@MainActor
protocol HeadPoseProvider: AnyObject {
    var availability: HeadPoseAvailability { get }
    func eventStream() -> AsyncStream<HeadPoseEvent>
    func recenter()
}

@MainActor
@Observable
final class HeadPoseController {
    private(set) var pose = HeadPose.identity
    private(set) var availability: HeadPoseAvailability

    @ObservationIgnored private let provider: any HeadPoseProvider
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(provider: any HeadPoseProvider) {
        self.provider = provider
        availability = provider.availability
        eventTask = Task { [weak self, provider] in
            for await event in provider.eventStream() {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .availability(let availability):
                    self.availability = availability
                case .pose(let pose):
                    self.pose = pose
                }
            }
        }
    }

    var statusText: String {
        switch availability {
        case .available:
            "AirPods 3DoF active"
        case .waiting(let reason):
            reason
        case .unavailable(let reason):
            reason
        }
    }

    var isTracking: Bool {
        availability == .available
    }

    func recenter() {
        pose = .identity
        provider.recenter()
    }
}

@MainActor
final class HeadLockedPoseProvider: HeadPoseProvider {
    let availability: HeadPoseAvailability = .available

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        AsyncStream { continuation in
            continuation.yield(.availability(.available))
            continuation.yield(.pose(.identity))
            continuation.finish()
        }
    }

    func recenter() {}
}

/// Reads head attitude from motion-capable AirPods using Apple's public Core
/// Motion API. All callbacks are delivered through the main operation queue so
/// the provider can safely drive the observable UI state.
@MainActor
final class AirPodsHeadPoseProvider: NSObject, HeadPoseProvider, CMHeadphoneMotionManagerDelegate {
    private(set) var availability: HeadPoseAvailability = .waiting(
        reason: "Connect motion-capable AirPods"
    )

    private let manager = CMHeadphoneMotionManager()
    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var referenceAttitude: CMAttitude?
    private var smoother = HeadPoseSmoother(responseTime: 0.025)

    override init() {
        let channel = AsyncStream<HeadPoseEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        events = channel.stream
        continuation = channel.continuation
        super.init()

        manager.delegate = self
        manager.startConnectionStatusUpdates()
        continuation.yield(.availability(availability))
        startMotionIfPossible()
    }

    deinit {
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        continuation.finish()
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        events
    }

    func recenter() {
        referenceAttitude = nil
        smoother.reset()
        continuation.yield(.pose(.identity))
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in
            self?.startMotionIfPossible()
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in
            self?.handleDisconnect()
        }
    }

    private func startMotionIfPossible() {
        guard manager.isDeviceMotionAvailable else {
            updateAvailability(.waiting(reason: "Connect motion-capable AirPods"))
            return
        }

        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            updateAvailability(.unavailable(reason: "AirPods Motion access denied"))
            return
        case .authorized, .notDetermined:
            break
        @unknown default:
            break
        }

        guard !manager.isDeviceMotionActive else { return }
        updateAvailability(.waiting(reason: "Starting AirPods tracking…"))
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                self?.consume(motion: motion, error: error)
            }
        }
    }

    private func consume(motion: CMDeviceMotion?, error: (any Error)?) {
        if let error {
            manager.stopDeviceMotionUpdates()
            updateAvailability(.unavailable(reason: error.localizedDescription))
            return
        }
        guard let motion else { return }

        if referenceAttitude == nil {
            referenceAttitude = motion.attitude.copy() as? CMAttitude
            smoother.reset()
            continuation.yield(.pose(.identity))
        }
        guard let referenceAttitude,
              let relative = motion.attitude.copy() as? CMAttitude else { return }

        relative.multiply(byInverseOf: referenceAttitude)
        let radiansToDegrees = 180.0 / Double.pi
        let sample = HeadPose(
            yaw: relative.yaw * radiansToDegrees,
            pitch: relative.pitch * radiansToDegrees,
            roll: relative.roll * radiansToDegrees,
            timestamp: motion.timestamp
        )
        continuation.yield(.pose(smoother.filter(sample)))
        updateAvailability(.available)
    }

    private func handleDisconnect() {
        manager.stopDeviceMotionUpdates()
        referenceAttitude = nil
        smoother.reset()
        continuation.yield(.pose(.identity))
        updateAvailability(.waiting(reason: "Connect motion-capable AirPods"))
    }

    private func updateAvailability(_ newValue: HeadPoseAvailability) {
        guard availability != newValue else { return }
        availability = newValue
        continuation.yield(.availability(newValue))
    }
}

struct HeadPoseSmoother: Sendable {
    let responseTime: TimeInterval
    private(set) var value: HeadPose?

    init(responseTime: TimeInterval = 0.025) {
        self.responseTime = responseTime
    }

    mutating func filter(_ sample: HeadPose) -> HeadPose {
        guard let previous = value else {
            value = sample
            return sample
        }

        let deltaTime = max(0, sample.timestamp - previous.timestamp)
        let alpha = responseTime <= 0 ? 1 : 1 - exp(-deltaTime / responseTime)
        let filtered = HeadPose(
            yaw: blendAngle(from: previous.yaw, to: sample.yaw, alpha: alpha),
            pitch: blendAngle(from: previous.pitch, to: sample.pitch, alpha: alpha),
            roll: blendAngle(from: previous.roll, to: sample.roll, alpha: alpha),
            timestamp: sample.timestamp
        )
        value = filtered
        return filtered
    }

    mutating func reset() {
        value = nil
    }

    private func blendAngle(from: Double, to: Double, alpha: Double) -> Double {
        let rawDifference = (to - from).truncatingRemainder(dividingBy: 360)
        let difference: Double
        if rawDifference > 180 {
            difference = rawDifference - 360
        } else if rawDifference < -180 {
            difference = rawDifference + 360
        } else {
            difference = rawDifference
        }
        return from + difference * alpha
    }
}

/// Public iOS APIs don't currently expose the XREAL Air v1 IMU over a direct
/// DisplayPort connection. This provider preserves the integration boundary
/// for a future supported USB/HID or BLE implementation.
@MainActor
final class XREALPoseProvider: HeadPoseProvider {
    let availability: HeadPoseAvailability = .unavailable(
        reason: "XREAL Air IMU is not available through a documented iOS API."
    )

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        AsyncStream { continuation in
            continuation.yield(.availability(availability))
            continuation.yield(.pose(.identity))
            continuation.finish()
        }
    }

    func recenter() {}
}
