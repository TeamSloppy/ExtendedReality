import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ExtendReality

struct HandGestureInterpreterTests {
    @Test
    func handModelContainsEveryVisionJoint() {
        #expect(HandJointName.allCases.count == 21)
    }

    @Test
    func cameraOrientationsMatchMirroredAndUnmirroredFrames() {
        #expect(HandCameraGeometry.imageOrientation(for: .portrait, mirrored: true) == .leftMirrored)
        #expect(HandCameraGeometry.imageOrientation(for: .portraitUpsideDown, mirrored: true) == .rightMirrored)
        #expect(HandCameraGeometry.imageOrientation(for: .landscapeLeft, mirrored: true) == .downMirrored)
        #expect(HandCameraGeometry.imageOrientation(for: .landscapeRight, mirrored: true) == .upMirrored)
        #expect(HandCameraGeometry.imageOrientation(for: .portrait, mirrored: false) == .right)
        #expect(HandCameraGeometry.imageOrientation(for: .landscapeLeft, mirrored: false) == .up)
    }

    @Test
    func previewRotationMatchesEveryDeviceOrientation() {
        #expect(HandCameraGeometry.previewRotationAngle(for: .portrait) == 90)
        #expect(HandCameraGeometry.previewRotationAngle(for: .portraitUpsideDown) == 270)
        #expect(HandCameraGeometry.previewRotationAngle(for: .landscapeLeft) == 180)
        #expect(HandCameraGeometry.previewRotationAngle(for: .landscapeRight) == 0)
    }

    @Test
    func lowConfidenceHandDoesNotDrivePointer() {
        var interpreter = HandGestureInterpreter()
        let hand = makeHand(confidence: 0.2)

        let events = interpreter.consume(HandPoseFrame(timestamp: 1, hands: [hand]))

        #expect(events.isEmpty)
        #expect(!interpreter.snapshot.isPointerVisible)
    }

    @Test
    func interactionInsetsMapToCanvasEdges() throws {
        var interpreter = HandGestureInterpreter()
        let hand = makeHand(indexTip: CGPoint(x: 0.12, y: 0.10), thumbTip: CGPoint(x: 0.40, y: 0.30))

        let events = interpreter.consume(HandPoseFrame(timestamp: 1, hands: [hand]))
        let position = try #require(movePosition(in: events))

        #expect(position.x == 0)
        #expect(position.y == 0)
        #expect(events.contains(.visibilityChanged(true)))
    }

    @Test
    func pinchUsesHysteresisWithoutDuplicateTransitions() {
        var interpreter = HandGestureInterpreter()
        let pinched = makeHand(indexTip: CGPoint(x: 0.52, y: 0.40), thumbTip: CGPoint(x: 0.49, y: 0.40))
        let ambiguous = makeHand(indexTip: CGPoint(x: 0.56, y: 0.40), thumbTip: CGPoint(x: 0.49, y: 0.40))
        let released = makeHand(indexTip: CGPoint(x: 0.60, y: 0.40), thumbTip: CGPoint(x: 0.49, y: 0.40))

        #expect(interpreter.consume(HandPoseFrame(timestamp: 1, hands: [pinched])).contains(.pointerDown))
        #expect(!interpreter.consume(HandPoseFrame(timestamp: 1.03, hands: [pinched])).contains(.pointerDown))
        #expect(!interpreter.consume(HandPoseFrame(timestamp: 1.06, hands: [ambiguous])).contains(.pointerUp))
        #expect(interpreter.consume(HandPoseFrame(timestamp: 1.09, hands: [released])).contains(.pointerUp))
        #expect(!interpreter.consume(HandPoseFrame(timestamp: 1.12, hands: [released])).contains(.pointerUp))
    }

    @Test
    func lostHandReleasesDragThenHidesPointer() {
        var interpreter = HandGestureInterpreter()
        let pinched = makeHand(indexTip: CGPoint(x: 0.52, y: 0.40), thumbTip: CGPoint(x: 0.49, y: 0.40))
        _ = interpreter.consume(HandPoseFrame(timestamp: 1, hands: [pinched]))

        #expect(interpreter.consume(HandPoseFrame(timestamp: 1.10, hands: [])).isEmpty)
        #expect(interpreter.consume(HandPoseFrame(timestamp: 1.26, hands: [])).contains(.pointerUp))
        #expect(interpreter.consume(HandPoseFrame(timestamp: 1.51, hands: [])).contains(.visibilityChanged(false)))
        #expect(!interpreter.snapshot.isPinching)
        #expect(!interpreter.snapshot.isPointerVisible)
    }

    @Test
    func preferredHandWinsWhenBothAreVisible() {
        var interpreter = HandGestureInterpreter()
        interpreter.preferredHand = .left
        let leftID = UUID()
        let rightID = UUID()
        let left = makeHand(id: leftID, chirality: .left, confidence: 0.7)
        let right = makeHand(id: rightID, chirality: .right, confidence: 0.95)

        _ = interpreter.consume(HandPoseFrame(timestamp: 1, hands: [right, left]))

        #expect(interpreter.snapshot.activeHandID == leftID)
    }

    @Test
    func twoPinchedHandsMagnifyFromTheirChangingDistance() throws {
        var interpreter = HandGestureInterpreter()
        let leftID = UUID()
        let rightID = UUID()
        let initialLeft = makeHand(
            id: leftID,
            chirality: .left,
            wristX: 0.30,
            pinchCenter: CGPoint(x: 0.30, y: 0.38)
        )
        let initialRight = makeHand(
            id: rightID,
            chirality: .right,
            wristX: 0.70,
            pinchCenter: CGPoint(x: 0.70, y: 0.38)
        )

        let began = interpreter.consume(
            HandPoseFrame(timestamp: 1, hands: [initialLeft, initialRight])
        )
        #expect(!began.contains(.pointerDown))
        #expect(interpreter.snapshot.isTwoHandGestureActive)
        #expect(interpreter.snapshot.pinchingHandIDs == Set([leftID, rightID]))

        let expandedLeft = makeHand(
            id: leftID,
            chirality: .left,
            wristX: 0.25,
            pinchCenter: CGPoint(x: 0.25, y: 0.38)
        )
        let expandedRight = makeHand(
            id: rightID,
            chirality: .right,
            wristX: 0.75,
            pinchCenter: CGPoint(x: 0.75, y: 0.38)
        )
        let changed = interpreter.consume(
            HandPoseFrame(timestamp: 1.03, hands: [expandedLeft, expandedRight])
        )
        let gesture = try #require(magnification(in: changed))

        #expect(abs(gesture.scaleDelta - 1.25) < 0.001)
        #expect(abs(gesture.center.x - 0.5) < 0.001)
    }

    @Test
    func startingTwoHandGestureReleasesAnActiveSingleHandDrag() {
        var interpreter = HandGestureInterpreter()
        let rightID = UUID()
        let right = makeHand(
            id: rightID,
            chirality: .right,
            wristX: 0.70,
            pinchCenter: CGPoint(x: 0.70, y: 0.38)
        )
        #expect(
            interpreter.consume(HandPoseFrame(timestamp: 1, hands: [right]))
                .contains(.pointerDown)
        )

        let left = makeHand(
            chirality: .left,
            wristX: 0.30,
            pinchCenter: CGPoint(x: 0.30, y: 0.38)
        )
        let events = interpreter.consume(
            HandPoseFrame(timestamp: 1.03, hands: [left, right])
        )

        #expect(events.contains(.pointerUp))
        #expect(!events.contains(.pointerDown))
        #expect(interpreter.snapshot.isTwoHandGestureActive)
        #expect(!interpreter.snapshot.isPinching)
    }

    @Test
    func handIdentityTrackerKeepsIDsAcrossMotionAndBriefOcclusion() throws {
        var tracker = HandIdentityTracker()
        let first = tracker.assignIdentities(
            to: [
                makeHand(chirality: .left, wristX: 0.25),
                makeHand(chirality: .right, wristX: 0.75),
            ],
            at: 1
        )
        let leftID = try #require(first.first(where: { $0.chirality == .left })?.id)
        let rightID = try #require(first.first(where: { $0.chirality == .right })?.id)

        _ = tracker.assignIdentities(to: [], at: 1.10)
        let reacquired = tracker.assignIdentities(
            to: [
                makeHand(chirality: .right, wristX: 0.71),
                makeHand(chirality: .left, wristX: 0.29),
            ],
            at: 1.20
        )

        #expect(reacquired.first(where: { $0.chirality == .left })?.id == leftID)
        #expect(reacquired.first(where: { $0.chirality == .right })?.id == rightID)
    }

    @Test
    func oneEuroFilterSmoothsLargeMovement() throws {
        var interpreter = HandGestureInterpreter()
        let first = makeHand(indexTip: CGPoint(x: 0.20, y: 0.40))
        let second = makeHand(indexTip: CGPoint(x: 0.80, y: 0.40))
        _ = interpreter.consume(HandPoseFrame(timestamp: 1, hands: [first]))

        let events = interpreter.consume(HandPoseFrame(timestamp: 1.033, hands: [second]))
        let position = try #require(movePosition(in: events))

        #expect(position.x > 0.10)
        #expect(position.x < 0.90)
    }

    private func movePosition(in events: [HandPointerEvent]) -> CGPoint? {
        for event in events {
            if case .move(let point) = event { return point }
        }
        return nil
    }

    private func magnification(
        in events: [HandPointerEvent]
    ) -> (scaleDelta: CGFloat, center: CGPoint)? {
        for event in events {
            if case .magnify(let scaleDelta, let center) = event {
                return (scaleDelta, center)
            }
        }
        return nil
    }

    private func makeHand(
        id: UUID = UUID(),
        chirality: HandChirality = .right,
        confidence: Float = 0.9,
        indexTip: CGPoint = CGPoint(x: 0.55, y: 0.35),
        thumbTip: CGPoint = CGPoint(x: 0.35, y: 0.35),
        wristX: CGFloat = 0.5,
        pinchCenter: CGPoint? = nil
    ) -> TrackedHandPose {
        var joints = Dictionary(uniqueKeysWithValues: HandJointName.allCases.map {
            ($0, HandJointSample(location: CGPoint(x: 0.5, y: 0.5), confidence: confidence))
        })
        joints[.wrist] = HandJointSample(location: CGPoint(x: wristX, y: 0.75), confidence: confidence)
        joints[.middleMCP] = HandJointSample(location: CGPoint(x: wristX, y: 0.50), confidence: confidence)
        if let pinchCenter {
            joints[.indexTip] = HandJointSample(
                location: CGPoint(x: pinchCenter.x + 0.01, y: pinchCenter.y),
                confidence: confidence
            )
            joints[.thumbTip] = HandJointSample(
                location: CGPoint(x: pinchCenter.x - 0.01, y: pinchCenter.y),
                confidence: confidence
            )
        } else {
            joints[.indexTip] = HandJointSample(location: indexTip, confidence: confidence)
            joints[.thumbTip] = HandJointSample(location: thumbTip, confidence: confidence)
        }
        return TrackedHandPose(
            id: id,
            chirality: chirality,
            joints: joints,
            boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.45),
            confidence: confidence
        )
    }
}
