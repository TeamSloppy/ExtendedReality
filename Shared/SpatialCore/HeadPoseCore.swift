import Foundation
import Observation

struct HeadPose: Equatable, Sendable {
    var yaw: Double
    var pitch: Double
    var roll: Double
    var timestamp: TimeInterval

    static let identity = HeadPose(yaw: 0, pitch: 0, roll: 0, timestamp: 0)

    func offset(relativeTo reference: HeadPose) -> HeadPose {
        HeadPose(
            yaw: Self.shortestAngle(from: reference.yaw, to: yaw),
            pitch: Self.shortestAngle(from: reference.pitch, to: pitch),
            roll: Self.shortestAngle(from: reference.roll, to: roll),
            timestamp: timestamp
        )
    }

    private static func shortestAngle(from: Double, to: Double) -> Double {
        let rawDifference = (to - from).truncatingRemainder(dividingBy: 360)
        return rawDifference > 180
            ? rawDifference - 360
            : (rawDifference < -180 ? rawDifference + 360 : rawDifference)
    }
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
    var displayName: String { get }
    var availability: HeadPoseAvailability { get }
    func eventStream() -> AsyncStream<HeadPoseEvent>
    func recenter()
}

@MainActor
protocol HeadPoseDiagnosticsProviding: AnyObject {
    var diagnosticsText: String? { get }
}

@MainActor
@Observable
final class HeadPoseController {
    static let isEnabledDefaultsKey = "headTracking.3DoFEnabled"

    private(set) var pose = HeadPose.identity
    private(set) var availability: HeadPoseAvailability
    private(set) var isEnabled: Bool

    @ObservationIgnored private let provider: any HeadPoseProvider
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var providerAvailability: HeadPoseAvailability
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(
        provider: any HeadPoseProvider,
        defaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.defaults = defaults
        providerAvailability = provider.availability
        let enabledPreference =
            defaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool ?? true
        isEnabled = enabledPreference
        availability = enabledPreference
            ? provider.availability
            : .unavailable(reason: "3DoF disabled")
        eventTask = Task { [weak self, provider] in
            for await event in provider.eventStream() {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .availability(let availability):
                    self.providerAvailability = availability
                    if self.isEnabled {
                        self.availability = availability
                    }
                case .pose(let pose):
                    if self.isEnabled {
                        self.pose = pose
                    }
                }
            }
        }
    }

    var statusText: String {
        switch availability {
        case .available: "\(provider.displayName) 3DoF active"
        case .waiting(let reason), .unavailable(let reason): reason
        }
    }

    var providerName: String { provider.displayName }

    var diagnosticsText: String? {
        (provider as? any HeadPoseDiagnosticsProviding)?.diagnosticsText
    }

    var isTracking: Bool { availability == .available }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.isEnabledDefaultsKey)
        pose = .identity

        if isEnabled {
            availability = providerAvailability
            provider.recenter()
        } else {
            availability = .unavailable(reason: "3DoF disabled")
        }
    }

    func recenter() {
        pose = .identity
        provider.recenter()
    }
}

@MainActor
final class HeadLockedPoseProvider: HeadPoseProvider {
    let displayName = "Head-locked"
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

struct HeadPoseSmoother: Sendable {
    let responseTime: TimeInterval
    private(set) var value: HeadPose?

    init(responseTime: TimeInterval = 0.025) { self.responseTime = responseTime }

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

    mutating func reset() { value = nil }

    private func blendAngle(from: Double, to: Double, alpha: Double) -> Double {
        let rawDifference = (to - from).truncatingRemainder(dividingBy: 360)
        let difference = rawDifference > 180
            ? rawDifference - 360
            : (rawDifference < -180 ? rawDifference + 360 : rawDifference)
        return from + difference * alpha
    }
}
