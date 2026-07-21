@preconcurrency import CoreMotion
import Foundation

@MainActor
final class MacAirPodsPoseProvider: NSObject, HeadPoseProvider, CMHeadphoneMotionManagerDelegate {
    let displayName = "AirPods"
    private(set) var availability: HeadPoseAvailability = .waiting(reason: "Connect motion-capable AirPods")

    private let manager = CMHeadphoneMotionManager()
    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var reference: CMAttitude?
    private var smoother = HeadPoseSmoother(responseTime: 0.025)
    private var started = false

    override init() {
        let channel = AsyncStream<HeadPoseEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
        events = channel.stream
        continuation = channel.continuation
        super.init()
        manager.delegate = self
        continuation.yield(.availability(availability))
    }

    func start() {
        guard !started else { return }
        started = true
        manager.startConnectionStatusUpdates()
        startIfAvailable()
    }

    deinit {
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        continuation.finish()
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> { events }

    func recenter() {
        reference = nil
        smoother.reset()
        continuation.yield(.pose(.identity))
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.startIfAvailable() }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.manager.stopDeviceMotionUpdates()
            self.reference = nil
            self.smoother.reset()
            self.continuation.yield(.pose(.identity))
            self.updateAvailability(.waiting(reason: "Connect motion-capable AirPods"))
        }
    }

    private func startIfAvailable() {
        guard manager.isDeviceMotionAvailable else {
            updateAvailability(.waiting(reason: "Connect motion-capable AirPods"))
            return
        }
        guard CMHeadphoneMotionManager.authorizationStatus() != .denied else {
            updateAvailability(.unavailable(reason: "AirPods Motion access denied"))
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        updateAvailability(.waiting(reason: "Starting AirPods tracking…"))
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated { self?.consume(motion, error: error) }
        }
    }

    private func consume(_ motion: CMDeviceMotion?, error: (any Error)?) {
        if let error {
            updateAvailability(.unavailable(reason: error.localizedDescription))
            return
        }
        guard let motion else { return }
        if reference == nil {
            reference = motion.attitude.copy() as? CMAttitude
            smoother.reset()
        }
        guard let reference, let relative = motion.attitude.copy() as? CMAttitude else { return }
        relative.multiply(byInverseOf: reference)
        let degrees = 180 / Double.pi
        continuation.yield(.pose(smoother.filter(HeadPose(
            yaw: relative.yaw * degrees,
            pitch: relative.pitch * degrees,
            roll: relative.roll * degrees,
            timestamp: motion.timestamp
        ))))
        updateAvailability(.available)
    }

    private func updateAvailability(_ value: HeadPoseAvailability) {
        guard value != availability else { return }
        availability = value
        continuation.yield(.availability(value))
    }
}

@MainActor
final class PreferredHeadPoseProvider: HeadPoseProvider {
    private(set) var displayName = "Head-locked"
    private(set) var availability: HeadPoseAvailability = .waiting(reason: "Head-locked fallback")

    private let primary: any HeadPoseProvider
    private let fallback: any HeadPoseProvider
    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var primaryAvailability: HeadPoseAvailability
    private var fallbackAvailability: HeadPoseAvailability
    private var primaryTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    init(primary: any HeadPoseProvider, fallback: any HeadPoseProvider) {
        self.primary = primary
        self.fallback = fallback
        primaryAvailability = primary.availability
        fallbackAvailability = fallback.availability
        let channel = AsyncStream<HeadPoseEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
        events = channel.stream
        continuation = channel.continuation
        primaryTask = observe(primary, isPrimary: true)
        fallbackTask = observe(fallback, isPrimary: false)
        updateSelection()
    }

    deinit {
        primaryTask?.cancel()
        fallbackTask?.cancel()
        continuation.finish()
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> { events }

    func activate() {
        (primary as? XREALUSBPoseProvider)?.start()
        (fallback as? MacAirPodsPoseProvider)?.start()
    }

    func recenter() {
        primary.recenter()
        fallback.recenter()
        continuation.yield(.pose(.identity))
    }

    private func observe(_ provider: any HeadPoseProvider, isPrimary: Bool) -> Task<Void, Never> {
        Task { [weak self, provider] in
            for await event in provider.eventStream() {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .availability(let value):
                    if isPrimary { self.primaryAvailability = value }
                    else { self.fallbackAvailability = value }
                    self.updateSelection()
                case .pose(let pose):
                    let usePrimary = self.primaryAvailability == .available
                    if (isPrimary && usePrimary) || (!isPrimary && !usePrimary && self.fallbackAvailability == .available) {
                        self.continuation.yield(.pose(pose))
                    }
                }
            }
        }
    }

    private func updateSelection() {
        if primaryAvailability == .available {
            displayName = primary.displayName
            availability = .available
        } else if fallbackAvailability == .available {
            displayName = fallback.displayName
            availability = .available
        } else {
            displayName = "Head-locked"
            availability = .waiting(reason: "USB/AirPods tracking unavailable — head-locked fallback")
            continuation.yield(.pose(.identity))
        }
        continuation.yield(.availability(availability))
    }
}
