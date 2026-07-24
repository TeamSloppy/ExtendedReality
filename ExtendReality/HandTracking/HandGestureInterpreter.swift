import CoreGraphics
import Foundation

struct HandGestureConfiguration: Equatable, Sendable {
    var horizontalInset: CGFloat = 0.12
    var verticalInset: CGFloat = 0.10
    var minimumConfidence: Float = 0.3
    var pinchDownRatio: CGFloat = 0.28
    var pinchUpRatio: CGFloat = 0.40
    var releaseDelay: TimeInterval = 0.15
    var hideDelay: TimeInterval = 0.40
    var minimumTwoHandDistance: CGFloat = 0.08
    var minimumMagnificationChange: CGFloat = 0.002
    var minimumCutoff = 1.0
    var beta = 0.04
    var derivativeCutoff = 1.0
}

struct HandGestureInterpreter: Sendable {
    private(set) var snapshot = HandTrackingSnapshot()

    var preferredHand: PreferredHand = .automatic
    var configuration = HandGestureConfiguration()

    private var activeChirality: HandChirality?
    private var lastWristLocation: CGPoint?
    private var missingSince: TimeInterval?
    private var twoHandMissingSince: TimeInterval?
    private var pinchStates: [UUID: Bool] = [:]
    private var pointerSuppressedUntilRelease: Set<UUID> = []
    private var previousTwoHandDistance: CGFloat?
    private var filter = OneEuroPointFilter()

    mutating func consume(_ frame: HandPoseFrame) -> [HandPointerEvent] {
        snapshot.hands = frame.hands
        let eligible = eligibleHands(from: frame.hands)
        let pinches = updatePinches(for: eligible)

        if pinches.count >= 2 {
            return consumeTwoHandGesture(pinches, at: frame.timestamp)
        }

        if snapshot.isTwoHandGestureActive {
            let start = twoHandMissingSince ?? frame.timestamp
            twoHandMissingSince = start
            if frame.timestamp - start < configuration.releaseDelay {
                return []
            }
            endTwoHandGesture()
        }

        guard let hand = selectHand(from: eligible) else {
            return consumeMissingHand(at: frame.timestamp)
        }

        missingSince = nil
        activeChirality = hand.chirality
        snapshot.activeHandID = hand.id
        lastWristLocation = hand.joint(.wrist, minimumConfidence: configuration.minimumConfidence)?.location

        guard let indexTip = hand.joint(
            .indexTip,
            minimumConfidence: configuration.minimumConfidence
        ) else {
            return consumeMissingHand(at: frame.timestamp)
        }

        let mapped = mapToPointer(indexTip.location)
        let filtered = filter.filter(
            mapped,
            timestamp: frame.timestamp,
            minimumCutoff: configuration.minimumCutoff,
            beta: configuration.beta,
            derivativeCutoff: configuration.derivativeCutoff
        )
        snapshot.pointerPosition = filtered

        var events: [HandPointerEvent] = [.move(filtered)]
        if !snapshot.isPointerVisible {
            snapshot.isPointerVisible = true
            events.insert(.visibilityChanged(true), at: 0)
        }

        let handIsPinching = pinchStates[hand.id] == true
        if !handIsPinching {
            pointerSuppressedUntilRelease.remove(hand.id)
        }
        if !snapshot.isPinching,
           handIsPinching,
           !pointerSuppressedUntilRelease.contains(hand.id) {
            snapshot.isPinching = true
            events.append(.pointerDown)
        } else if snapshot.isPinching, !handIsPinching {
            snapshot.isPinching = false
            events.append(.pointerUp)
        }
        return events
    }

    mutating func stop() -> [HandPointerEvent] {
        var events: [HandPointerEvent] = []
        if snapshot.isPinching { events.append(.pointerUp) }
        if snapshot.isPointerVisible { events.append(.visibilityChanged(false)) }
        snapshot = HandTrackingSnapshot(pointerPosition: snapshot.pointerPosition)
        activeChirality = nil
        lastWristLocation = nil
        missingSince = nil
        twoHandMissingSince = nil
        pinchStates.removeAll()
        pointerSuppressedUntilRelease.removeAll()
        previousTwoHandDistance = nil
        filter.reset()
        return events
    }

    private mutating func consumeMissingHand(at timestamp: TimeInterval) -> [HandPointerEvent] {
        let start = missingSince ?? timestamp
        missingSince = start
        var events: [HandPointerEvent] = []

        if snapshot.isPinching, timestamp - start >= configuration.releaseDelay {
            snapshot.isPinching = false
            events.append(.pointerUp)
        }
        if snapshot.isPointerVisible, timestamp - start >= configuration.hideDelay {
            snapshot.isPointerVisible = false
            snapshot.activeHandID = nil
            activeChirality = nil
            lastWristLocation = nil
            pinchStates.removeAll()
            pointerSuppressedUntilRelease.removeAll()
            previousTwoHandDistance = nil
            snapshot.pinchingHandIDs = []
            snapshot.isTwoHandGestureActive = false
            snapshot.twoHandGestureCenter = nil
            filter.reset()
            events.append(.visibilityChanged(false))
        }
        return events
    }

    private func eligibleHands(from hands: [TrackedHandPose]) -> [TrackedHandPose] {
        hands.filter { hand in
            hand.joint(.indexTip, minimumConfidence: configuration.minimumConfidence) != nil
                && hand.joint(.thumbTip, minimumConfidence: configuration.minimumConfidence) != nil
                && hand.joint(.wrist, minimumConfidence: configuration.minimumConfidence) != nil
                && hand.joint(.middleMCP, minimumConfidence: configuration.minimumConfidence) != nil
        }
    }

    private func selectHand(from eligible: [TrackedHandPose]) -> TrackedHandPose? {
        guard !eligible.isEmpty else { return nil }

        let preferred: HandChirality? = switch preferredHand {
        case .automatic: activeChirality
        case .left: .left
        case .right: .right
        }
        let candidates = preferred.map { chirality in
            eligible.filter { $0.chirality == chirality }
        }.flatMap { $0.isEmpty ? nil : $0 } ?? eligible

        if let lastWristLocation {
            return candidates.min { lhs, rhs in
                let left = lhs.joint(.wrist, minimumConfidence: configuration.minimumConfidence)?.location
                let right = rhs.joint(.wrist, minimumConfidence: configuration.minimumConfidence)?.location
                return distance(left ?? .zero, lastWristLocation) < distance(right ?? .zero, lastWristLocation)
            }
        }
        return candidates.max { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            return lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }
    }

    private mutating func updatePinches(for hands: [TrackedHandPose]) -> [(hand: TrackedHandPose, center: CGPoint)] {
        var pinches: [(hand: TrackedHandPose, center: CGPoint)] = []
        var visiblePinchingIDs: Set<UUID> = []

        for hand in hands {
            guard let indexTip = hand.joint(.indexTip, minimumConfidence: configuration.minimumConfidence),
                  let thumbTip = hand.joint(.thumbTip, minimumConfidence: configuration.minimumConfidence),
                  let wrist = hand.joint(.wrist, minimumConfidence: configuration.minimumConfidence),
                  let middleMCP = hand.joint(.middleMCP, minimumConfidence: configuration.minimumConfidence) else {
                continue
            }
            let palmScale = max(distance(wrist.location, middleMCP.location), 0.001)
            let pinchRatio = distance(indexTip.location, thumbTip.location) / palmScale
            let wasPinching = pinchStates[hand.id] == true
            let isPinching = wasPinching
                ? pinchRatio < configuration.pinchUpRatio
                : pinchRatio <= configuration.pinchDownRatio
            pinchStates[hand.id] = isPinching

            if isPinching {
                visiblePinchingIDs.insert(hand.id)
                pinches.append((
                    hand,
                    CGPoint(
                        x: (indexTip.location.x + thumbTip.location.x) / 2,
                        y: (indexTip.location.y + thumbTip.location.y) / 2
                    )
                ))
            } else {
                pointerSuppressedUntilRelease.remove(hand.id)
            }
        }

        snapshot.pinchingHandIDs = visiblePinchingIDs
        return pinches
    }

    private mutating func consumeTwoHandGesture(
        _ pinches: [(hand: TrackedHandPose, center: CGPoint)],
        at timestamp: TimeInterval
    ) -> [HandPointerEvent] {
        let pair = Array(pinches.prefix(2))
        let rawCenter = CGPoint(
            x: (pair[0].center.x + pair[1].center.x) / 2,
            y: (pair[0].center.y + pair[1].center.y) / 2
        )
        let center = mapToPointer(rawCenter)
        let currentDistance = distance(pair[0].center, pair[1].center)
        var events: [HandPointerEvent] = []

        missingSince = nil
        twoHandMissingSince = nil
        snapshot.twoHandGestureCenter = center
        snapshot.pointerPosition = center
        snapshot.activeHandID = pair[0].hand.id
        activeChirality = pair[0].hand.chirality
        lastWristLocation = pair[0].hand.joint(
            .wrist,
            minimumConfidence: configuration.minimumConfidence
        )?.location

        if !snapshot.isPointerVisible {
            snapshot.isPointerVisible = true
            events.append(.visibilityChanged(true))
        }
        if snapshot.isPinching {
            snapshot.isPinching = false
            events.append(.pointerUp)
        }

        pointerSuppressedUntilRelease.formUnion(pair.map { $0.hand.id })
        if !snapshot.isTwoHandGestureActive {
            snapshot.isTwoHandGestureActive = true
            previousTwoHandDistance = currentDistance
            return events
        }

        guard let previousTwoHandDistance,
              previousTwoHandDistance >= configuration.minimumTwoHandDistance,
              currentDistance >= configuration.minimumTwoHandDistance else {
            self.previousTwoHandDistance = currentDistance
            return events
        }

        let delta = (currentDistance / previousTwoHandDistance).clamped(to: 0.75 ... 1.333)
        self.previousTwoHandDistance = currentDistance
        if delta.isFinite, abs(delta - 1) >= configuration.minimumMagnificationChange {
            events.append(.magnify(scaleDelta: delta, center: center))
        }
        return events
    }

    private mutating func endTwoHandGesture() {
        snapshot.isTwoHandGestureActive = false
        snapshot.twoHandGestureCenter = nil
        twoHandMissingSince = nil
        previousTwoHandDistance = nil
    }

    private func mapToPointer(_ point: CGPoint) -> CGPoint {
        let horizontalRange = max(1 - configuration.horizontalInset * 2, 0.01)
        let verticalRange = max(1 - configuration.verticalInset * 2, 0.01)
        return CGPoint(
            x: ((point.x - configuration.horizontalInset) / horizontalRange).clamped(to: 0 ... 1),
            y: ((point.y - configuration.verticalInset) / verticalRange).clamped(to: 0 ... 1)
        )
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private struct OneEuroPointFilter: Sendable {
    private var x = OneEuroScalarFilter()
    private var y = OneEuroScalarFilter()

    mutating func filter(
        _ point: CGPoint,
        timestamp: TimeInterval,
        minimumCutoff: Double,
        beta: Double,
        derivativeCutoff: Double
    ) -> CGPoint {
        CGPoint(
            x: x.filter(Double(point.x), timestamp: timestamp, minimumCutoff: minimumCutoff, beta: beta, derivativeCutoff: derivativeCutoff),
            y: y.filter(Double(point.y), timestamp: timestamp, minimumCutoff: minimumCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        )
    }

    mutating func reset() {
        x = OneEuroScalarFilter()
        y = OneEuroScalarFilter()
    }
}

private struct OneEuroScalarFilter: Sendable {
    private var previousValue: Double?
    private var previousDerivative = 0.0
    private var previousTimestamp: TimeInterval?

    mutating func filter(
        _ value: Double,
        timestamp: TimeInterval,
        minimumCutoff: Double,
        beta: Double,
        derivativeCutoff: Double
    ) -> Double {
        guard let previousValue, let previousTimestamp, timestamp > previousTimestamp else {
            self.previousValue = value
            self.previousTimestamp = timestamp
            return value
        }
        let delta = timestamp - previousTimestamp
        let derivative = (value - previousValue) / delta
        let filteredDerivative = lowPass(
            derivative,
            previous: previousDerivative,
            alpha: smoothingFactor(delta: delta, cutoff: derivativeCutoff)
        )
        let cutoff = minimumCutoff + beta * abs(filteredDerivative)
        let filtered = lowPass(
            value,
            previous: previousValue,
            alpha: smoothingFactor(delta: delta, cutoff: cutoff)
        )
        self.previousValue = filtered
        self.previousDerivative = filteredDerivative
        self.previousTimestamp = timestamp
        return filtered
    }

    private func smoothingFactor(delta: TimeInterval, cutoff: Double) -> Double {
        let radius = 1 / (2 * Double.pi * max(cutoff, 0.001))
        return 1 / (1 + radius / delta)
    }

    private func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}
