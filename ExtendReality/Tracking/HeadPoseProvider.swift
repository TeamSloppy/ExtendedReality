@preconcurrency import CoreMotion
import Foundation
import QuartzCore

/// Reads head attitude from motion-capable AirPods using Apple's public Core
/// Motion API. All callbacks are delivered through the main operation queue so
/// the provider can safely drive the observable UI state.
@MainActor
final class AirPodsHeadPoseProvider: NSObject, HeadPoseProvider, CMHeadphoneMotionManagerDelegate {
    let displayName = "AirPods"
    private(set) var availability: HeadPoseAvailability = .waiting(
        reason: "Connect motion-capable AirPods"
    )

    private let manager = CMHeadphoneMotionManager()
    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var referenceAttitude: CMAttitude?
    private var smoother = HeadPoseSmoother(responseTime: 0.025)
    private var displayLink: CADisplayLink?
    private var lastConsumedMotionTimestamp: TimeInterval?

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
        MainActor.assumeIsolated {
            displayLink?.invalidate()
            manager.stopDeviceMotionUpdates()
            manager.stopConnectionStatusUpdates()
        }
        continuation.finish()
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        events
    }

    func recenter() {
        referenceAttitude = nil
        lastConsumedMotionTimestamp = nil
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
        manager.startDeviceMotionUpdates()
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(consumeLatestMotion))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 60,
            preferred: 60
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func consumeLatestMotion() {
        guard let motion = manager.deviceMotion else { return }
        if let lastConsumedMotionTimestamp,
           motion.timestamp == lastConsumedMotionTimestamp {
            return
        }
        lastConsumedMotionTimestamp = motion.timestamp
        consume(motion: motion, error: nil)
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
        displayLink?.invalidate()
        displayLink = nil
        manager.stopDeviceMotionUpdates()
        referenceAttitude = nil
        lastConsumedMotionTimestamp = nil
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

/// Public iOS APIs don't currently expose the XREAL Air v1 IMU over a direct
/// DisplayPort connection. This provider preserves the integration boundary
/// for a future supported USB/HID or BLE implementation.
@MainActor
final class XREALPoseProvider: HeadPoseProvider {
    let displayName = "XREAL"
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
