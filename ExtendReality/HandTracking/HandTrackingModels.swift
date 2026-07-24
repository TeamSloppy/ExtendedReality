import CoreGraphics
import Foundation

enum HandChirality: String, CaseIterable, Identifiable, Sendable {
    case left
    case right
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .unknown: "Unknown"
        }
    }
}

enum PreferredHand: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

enum HandJointName: String, CaseIterable, Sendable {
    case wrist
    case thumbCMC
    case thumbMP
    case thumbIP
    case thumbTip
    case indexMCP
    case indexPIP
    case indexDIP
    case indexTip
    case middleMCP
    case middlePIP
    case middleDIP
    case middleTip
    case ringMCP
    case ringPIP
    case ringDIP
    case ringTip
    case littleMCP
    case littlePIP
    case littleDIP
    case littleTip
}

struct HandJointSample: Equatable, Sendable {
    let location: CGPoint
    let confidence: Float
}

struct TrackedHandPose: Equatable, Sendable, Identifiable {
    let id: UUID
    let chirality: HandChirality
    let joints: [HandJointName: HandJointSample]
    let boundingBox: CGRect
    let confidence: Float

    func joint(_ name: HandJointName, minimumConfidence: Float = 0.3) -> HandJointSample? {
        guard let sample = joints[name], sample.confidence >= minimumConfidence else { return nil }
        return sample
    }
}

struct HandPoseFrame: Equatable, Sendable {
    let timestamp: TimeInterval
    let hands: [TrackedHandPose]
}

enum HandPointerEvent: Equatable, Sendable {
    case move(CGPoint)
    case pointerDown
    case pointerUp
    case magnify(scaleDelta: CGFloat, center: CGPoint)
    case visibilityChanged(Bool)
}

struct HandTrackingSnapshot: Equatable, Sendable {
    var hands: [TrackedHandPose] = []
    var activeHandID: UUID?
    var pointerPosition = CGPoint(x: 0.5, y: 0.5)
    var isPointerVisible = false
    var isPinching = false
    var pinchingHandIDs: Set<UUID> = []
    var isTwoHandGestureActive = false
    var twoHandGestureCenter: CGPoint?
}

enum HandTrackingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case running
    case denied
    case unavailable
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Hand tracking off"
        case .requestingPermission: "Requesting camera access…"
        case .running: "Hand tracking active"
        case .denied: "Camera access denied"
        case .unavailable: "No compatible camera"
        case .failed(let message): message
        }
    }
}

struct HandCameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isTrueDepth: Bool
    let isContinuity: Bool
}

enum HandCameraOrientation: Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}

enum HandSkeleton {
    static let segments: [(HandJointName, HandJointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]
}
