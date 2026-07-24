@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
@preconcurrency import Vision

enum HandCameraGeometry {
    static func previewRotationAngle(for orientation: HandCameraOrientation) -> CGFloat {
        switch orientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        }
    }

    static func imageOrientation(
        for orientation: HandCameraOrientation,
        mirrored: Bool
    ) -> CGImagePropertyOrientation {
        switch (orientation, mirrored) {
        case (.portrait, true): .leftMirrored
        case (.portraitUpsideDown, true): .rightMirrored
        case (.landscapeLeft, true): .downMirrored
        case (.landscapeRight, true): .upMirrored
        case (.portrait, false): .right
        case (.portraitUpsideDown, false): .left
        case (.landscapeLeft, false): .up
        case (.landscapeRight, false): .down
        }
    }
}

final class VisionHandPoseDetector: @unchecked Sendable {
    private let request: VNDetectHumanHandPoseRequest
    private let handler = VNSequenceRequestHandler()
    private var identityTracker = HandIdentityTracker()

    init(maximumHandCount: Int = 2) {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = maximumHandCount
    }

    func detect(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) -> HandPoseFrame {
        do {
            try handler.perform([request], on: pixelBuffer, orientation: orientation)
            let detectedHands = (request.results ?? []).map(makeHand)
            let hands = identityTracker.assignIdentities(to: detectedHands, at: timestamp)
            return HandPoseFrame(timestamp: timestamp, hands: hands)
        } catch {
            return HandPoseFrame(timestamp: timestamp, hands: [])
        }
    }

    private func makeHand(from observation: VNHumanHandPoseObservation) -> TrackedHandPose {
        var joints: [HandJointName: HandJointSample] = [:]
        for name in HandJointName.allCases {
            guard let point = try? observation.recognizedPoint(name.visionName) else { continue }
            joints[name] = HandJointSample(
                location: CGPoint(x: point.location.x, y: 1 - point.location.y),
                confidence: point.confidence
            )
        }
        let confident = joints.values.filter { $0.confidence >= 0.3 }
        let box: CGRect
        if let first = confident.first {
            let xs = confident.map(\.location.x)
            let ys = confident.map(\.location.y)
            box = CGRect(
                x: xs.min() ?? first.location.x,
                y: ys.min() ?? first.location.y,
                width: (xs.max() ?? first.location.x) - (xs.min() ?? first.location.x),
                height: (ys.max() ?? first.location.y) - (ys.min() ?? first.location.y)
            )
        } else {
            box = .zero
        }
        let confidence = confident.isEmpty
            ? 0
            : confident.reduce(Float.zero) { $0 + $1.confidence } / Float(confident.count)
        return TrackedHandPose(
            id: UUID(),
            chirality: observation.chirality.handChirality,
            joints: joints,
            boundingBox: box,
            confidence: confidence
        )
    }
}

struct HandIdentityTracker: Sendable {
    private struct Track: Sendable {
        var hand: TrackedHandPose
        var lastSeenAt: TimeInterval
    }

    private var tracks: [UUID: Track] = [:]
    private let maximumMatchDistance: CGFloat
    private let retentionDuration: TimeInterval

    init(
        maximumMatchDistance: CGFloat = 0.32,
        retentionDuration: TimeInterval = 0.40
    ) {
        self.maximumMatchDistance = maximumMatchDistance
        self.retentionDuration = retentionDuration
    }

    mutating func assignIdentities(
        to detectedHands: [TrackedHandPose],
        at timestamp: TimeInterval
    ) -> [TrackedHandPose] {
        tracks = tracks.filter { timestamp - $0.value.lastSeenAt <= retentionDuration }
        var availableTrackIDs = Set(tracks.keys)
        var identified: [TrackedHandPose] = []

        for hand in detectedHands.sorted(by: { $0.confidence > $1.confidence }) {
            let matchedID = bestMatch(for: hand, among: availableTrackIDs)
            let id = matchedID ?? UUID()
            availableTrackIDs.remove(id)
            let tracked = hand.withID(id)
            tracks[id] = Track(hand: tracked, lastSeenAt: timestamp)
            identified.append(tracked)
        }
        return identified
    }

    private func bestMatch(
        for hand: TrackedHandPose,
        among candidateIDs: Set<UUID>
    ) -> UUID? {
        let exactChirality = candidateIDs.filter { id in
            guard let previous = tracks[id]?.hand else { return false }
            return hand.chirality == .unknown
                || previous.chirality == .unknown
                || previous.chirality == hand.chirality
        }
        let candidates = exactChirality.isEmpty ? candidateIDs : exactChirality
        return candidates
            .compactMap { id -> (UUID, CGFloat)? in
                guard let previous = tracks[id]?.hand else { return nil }
                let distance = trackingDistance(from: previous, to: hand)
                return distance <= maximumMatchDistance ? (id, distance) : nil
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func trackingDistance(from previous: TrackedHandPose, to current: TrackedHandPose) -> CGFloat {
        let previousAnchor = previous.joints[.wrist]?.location
            ?? CGPoint(x: previous.boundingBox.midX, y: previous.boundingBox.midY)
        let currentAnchor = current.joints[.wrist]?.location
            ?? CGPoint(x: current.boundingBox.midX, y: current.boundingBox.midY)
        return hypot(previousAnchor.x - currentAnchor.x, previousAnchor.y - currentAnchor.y)
    }
}

private extension TrackedHandPose {
    func withID(_ id: UUID) -> TrackedHandPose {
        TrackedHandPose(
            id: id,
            chirality: chirality,
            joints: joints,
            boundingBox: boundingBox,
            confidence: confidence
        )
    }
}

private extension HandJointName {
    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: .wrist
        case .thumbCMC: .thumbCMC
        case .thumbMP: .thumbMP
        case .thumbIP: .thumbIP
        case .thumbTip: .thumbTip
        case .indexMCP: .indexMCP
        case .indexPIP: .indexPIP
        case .indexDIP: .indexDIP
        case .indexTip: .indexTip
        case .middleMCP: .middleMCP
        case .middlePIP: .middlePIP
        case .middleDIP: .middleDIP
        case .middleTip: .middleTip
        case .ringMCP: .ringMCP
        case .ringPIP: .ringPIP
        case .ringDIP: .ringDIP
        case .ringTip: .ringTip
        case .littleMCP: .littleMCP
        case .littlePIP: .littlePIP
        case .littleDIP: .littleDIP
        case .littleTip: .littleTip
        }
    }
}

private extension VNChirality {
    var handChirality: HandChirality {
        switch self {
        case .left: .left
        case .right: .right
        default: .unknown
        }
    }
}
