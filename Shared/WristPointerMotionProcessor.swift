import Foundation

/// Converts Apple Watch gyroscope samples into small, stable pointer movements.
///
/// The processor is deliberately independent of Core Motion so its timing and
/// filtering behaviour can be verified without a physical watch.
struct WristPointerMotionProcessor {
    struct Delta: Equatable, Sendable {
        let x: Double
        let y: Double
    }

    private static let deadZone = 0.055
    private static let maximumRotationRate = 5.5
    private static let filterResponse = 14.0
    private static let pointerGain = 0.15
    private static let sendInterval = 1.0 / 30.0
    private static let minimumDelta = 0.00008
    private static let maximumSampleInterval = 0.12

    private var filteredHorizontalRate = 0.0
    private var filteredVerticalRate = 0.0
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var lastSampleAt: TimeInterval?
    private var lastSentAt: TimeInterval?

    mutating func reset() {
        filteredHorizontalRate = 0
        filteredVerticalRate = 0
        accumulatedX = 0
        accumulatedY = 0
        lastSampleAt = nil
        lastSentAt = nil
    }

    mutating func consume(
        rotationRateX: Double,
        rotationRateY: Double,
        timestamp: TimeInterval,
        sensitivity: Double,
        invertVertical: Bool
    ) -> Delta? {
        guard rotationRateX.isFinite, rotationRateY.isFinite, timestamp.isFinite else { return nil }

        guard let previousSampleAt = lastSampleAt else {
            lastSampleAt = timestamp
            lastSentAt = timestamp
            return nil
        }

        let rawInterval = timestamp - previousSampleAt
        lastSampleAt = timestamp
        guard rawInterval > 0 else { return nil }

        // A pause (for example, while the display wakes) must not turn the
        // first subsequent sample into a large cursor jump.
        guard rawInterval <= Self.maximumSampleInterval else {
            reset()
            lastSampleAt = timestamp
            lastSentAt = timestamp
            return nil
        }

        let horizontalRate = min(max(rotationRateY, -Self.maximumRotationRate), Self.maximumRotationRate)
        let verticalRate = min(max(rotationRateX, -Self.maximumRotationRate), Self.maximumRotationRate)
        let filterWeight = 1 - exp(-Self.filterResponse * rawInterval)
        filteredHorizontalRate += filterWeight * (horizontalRate - filteredHorizontalRate)
        filteredVerticalRate += filterWeight * (verticalRate - filteredVerticalRate)

        let horizontal = adjustedRate(filteredHorizontalRate)
        let vertical = adjustedRate(filteredVerticalRate)
        let gain = Self.pointerGain * min(max(sensitivity, 0.4), 1.8)
        accumulatedX += horizontal * rawInterval * gain
        accumulatedY += vertical * rawInterval * gain * (invertVertical ? -1 : 1)

        guard let lastSentAt, timestamp - lastSentAt >= Self.sendInterval else { return nil }
        self.lastSentAt = timestamp

        let delta = Delta(x: accumulatedX, y: accumulatedY)
        accumulatedX = 0
        accumulatedY = 0
        guard abs(delta.x) >= Self.minimumDelta || abs(delta.y) >= Self.minimumDelta else { return nil }
        return delta
    }

    private func adjustedRate(_ rate: Double) -> Double {
        guard abs(rate) > Self.deadZone else { return 0 }

        let direction = rate < 0 ? -1.0 : 1.0
        let outsideDeadZone = abs(rate) - Self.deadZone
        // A light response curve preserves fine control while allowing a quick
        // wrist turn to cross the virtual canvas without repeated large swings.
        let acceleration = 1 + min(outsideDeadZone / 4, 1) * 0.2
        return direction * outsideDeadZone * acceleration
    }
}
