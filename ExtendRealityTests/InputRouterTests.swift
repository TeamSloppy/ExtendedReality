import CoreGraphics
import XCTest
@testable import ExtendReality

@MainActor
final class InputRouterTests: XCTestCase {
    func testPointerIsClampedAndDispatched() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        router.register(target, for: id)

        router.movePointer(delta: CGVector(dx: 2, dy: -2), in: id)

        XCTAssertEqual(router.cursor, CGPoint(x: 1, y: 0))
        XCTAssertEqual(target.commands, [.pointerMoved(normalizedPosition: CGPoint(x: 1, y: 0))])
    }

    func testAbsolutePointerPositionIsClampedAndDispatched() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        router.register(target, for: id)

        router.movePointer(to: CGPoint(x: -0.25, y: 1.25), in: id)

        XCTAssertEqual(router.cursor, CGPoint(x: 0, y: 1))
        XCTAssertEqual(target.commands, [.pointerMoved(normalizedPosition: CGPoint(x: 0, y: 1))])
    }

    func testTextAndBackAreSentToFocusedTarget() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        router.register(target, for: id)

        router.insertText("hello", in: id)
        router.back(in: id)

        XCTAssertEqual(target.commands, [.insertText("hello"), .back])
    }

    func testPointerCoordinatesAreMappedIntoWindowSurface() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        let size = CGSize(width: 1_000, height: 500)
        let surfaceMidY = WindowChromeLayout.titleBarHeight
            + (size.height - WindowChromeLayout.titleBarHeight - WindowChromeLayout.ornamentHeight) / 2
        router.register(target, for: id)
        router.updateWindowLayout(WindowChromeLayout(size: size), for: id)

        router.movePointer(to: CGPoint(x: 0.25, y: surfaceMidY / size.height), in: id)

        XCTAssertEqual(
            target.commands,
            [.pointerMoved(normalizedPosition: CGPoint(x: 0.25, y: 0.5))]
        )
    }

    func testPointerOutsideWindowIsNotDispatchedToSurface() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        router.register(target, for: id)
        router.updateWindowLayout(
            WindowChromeLayout(
                frame: CGRect(x: 200, y: 200, width: 600, height: 500),
                in: CGSize(width: 1_000, height: 1_000)
            ),
            for: id
        )

        router.movePointer(to: CGPoint(x: 0.5, y: 0.05), in: id)

        XCTAssertEqual(router.cursor, CGPoint(x: 0.5, y: 0.05))
        XCTAssertTrue(target.commands.isEmpty)
        XCTAssertEqual(router.chromeRegion(in: id), .outside)
    }

    func testStatusBarActionCanBeClickedWhileWindowIsActive() {
        let router = InputRouter()
        let windowID = UUID()
        var receivedAction: StatusBarAction?
        router.updateStatusBarHitFrames(
            [.dashboard: CGRect(x: 400, y: 20, width: 200, height: 80)],
            in: CGSize(width: 1_000, height: 1_000)
        )
        router.statusBarActionHandler = { receivedAction = $0 }

        router.movePointer(to: CGPoint(x: 0.5, y: 0.05), in: windowID)
        router.pointerDown(in: windowID)
        router.pointerUp(in: windowID)

        XCTAssertEqual(receivedAction, .dashboard)
    }

    func testChromeButtonRunsActionWithoutClickingSurface() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        var receivedAction: WindowChromeAction?
        router.register(target, for: id)
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)
        router.chromeActionHandler = { _, action in receivedAction = action }

        router.movePointer(to: CGPoint(x: 0.02, y: 0.98), in: id)
        router.pointerDown(in: id)
        router.pointerUp(in: id)

        XCTAssertEqual(receivedAction, .close)
        XCTAssertTrue(target.commands.isEmpty)
    }

    func testMoveHandleCanBeDetectedByTrackpad() {
        let router = InputRouter()
        let id = UUID()
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)

        router.movePointer(to: CGPoint(x: 0.5, y: 0.98), in: id)

        XCTAssertEqual(router.chromeRegion(in: id), .moveHandle)
    }

    func testWindowDistanceButtonsRunChromeActions() {
        let router = InputRouter()
        let id = UUID()
        var receivedActions: [WindowChromeAction] = []
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)
        router.chromeActionHandler = { _, action in receivedActions.append(action) }

        router.movePointer(to: CGPoint(x: 0.08, y: 0.98), in: id)
        router.pointerDown(in: id)
        router.pointerUp(in: id)
        router.movePointer(to: CGPoint(x: 0.92, y: 0.98), in: id)
        router.pointerDown(in: id)
        router.pointerUp(in: id)

        XCTAssertEqual(receivedActions, [.moveFarther, .moveCloser])
    }

    func testDashboardClickRunsActionWhenThereIsNoActiveWindow() {
        let router = InputRouter()
        let itemID = UUID()
        var receivedItemID: UUID?
        router.dashboardActionHandler = { receivedItemID = $0 }
        router.updateDashboardHitFrames(
            [itemID: CGRect(x: 100, y: 100, width: 200, height: 200)],
            in: CGSize(width: 1_000, height: 1_000)
        )

        router.movePointer(to: CGPoint(x: 0.2, y: 0.2), in: nil)
        router.pointerDown(in: nil)
        router.pointerUp(in: nil)

        XCTAssertEqual(receivedItemID, itemID)
    }

    func testDashboardClickIsCancelledAfterCursorLeavesItem() {
        let router = InputRouter()
        let itemID = UUID()
        var receivedItemID: UUID?
        router.dashboardActionHandler = { receivedItemID = $0 }
        router.updateDashboardHitFrames(
            [itemID: CGRect(x: 100, y: 100, width: 200, height: 200)],
            in: CGSize(width: 1_000, height: 1_000)
        )

        router.movePointer(to: CGPoint(x: 0.2, y: 0.2), in: nil)
        router.pointerDown(in: nil)
        router.movePointer(to: CGPoint(x: 0.8, y: 0.8), in: nil)
        router.pointerUp(in: nil)

        XCTAssertNil(receivedItemID)
    }

    func testAppSwitcherConsumesInputAndSelectsWindow() {
        let router = InputRouter()
        let activeWindowID = UUID()
        let selectedWindowID = UUID()
        let target = InputTargetSpy()
        var receivedWindowID: UUID?
        var receivedStatusAction: StatusBarAction?
        router.register(target, for: activeWindowID)
        router.updateWindowLayout(
            WindowChromeLayout(size: CGSize(width: 1_000, height: 1_000)),
            for: activeWindowID
        )
        router.updateStatusBarHitFrames(
            [.dashboard: CGRect(x: 100, y: 100, width: 200, height: 200)],
            in: CGSize(width: 1_000, height: 1_000)
        )
        router.updateAppSwitcherHitFrames(
            [selectedWindowID: CGRect(x: 100, y: 100, width: 200, height: 200)],
            in: CGSize(width: 1_000, height: 1_000)
        )
        router.statusBarActionHandler = { receivedStatusAction = $0 }
        router.appSwitcherActionHandler = { receivedWindowID = $0 }
        router.setAppSwitcherPresented(true)

        router.movePointer(to: CGPoint(x: 0.2, y: 0.2), in: activeWindowID)
        router.pointerDown(in: activeWindowID)
        router.pointerUp(in: activeWindowID)

        XCTAssertEqual(receivedWindowID, selectedWindowID)
        XCTAssertNil(receivedStatusAction)
        XCTAssertTrue(target.commands.isEmpty)
    }

    func testCursorHidesAfterInactivityAndReappearsAfterMovement() async throws {
        let router = InputRouter(cursorInactivityDuration: .milliseconds(30))

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(router.isCursorVisible)

        router.movePointer(to: CGPoint(x: 0.5, y: 0.5), in: nil)
        XCTAssertFalse(router.isCursorVisible)

        router.movePointer(to: CGPoint(x: 0.6, y: 0.5), in: nil)
        XCTAssertTrue(router.isCursorVisible)
    }

    func testHoverFeedbackRunsOnceWhenEnteringInteractiveTarget() {
        let router = InputRouter()
        var feedbackCount = 0
        router.pointerHoverHandler = { feedbackCount += 1 }
        router.updateStatusBarHitFrames(
            [.dashboard: CGRect(x: 100, y: 100, width: 200, height: 200)],
            in: CGSize(width: 1_000, height: 1_000)
        )

        router.movePointer(to: CGPoint(x: 0.15, y: 0.15), in: nil)
        router.movePointer(to: CGPoint(x: 0.2, y: 0.2), in: nil)

        XCTAssertEqual(feedbackCount, 1)
    }

    func testHoverFeedbackRunsWhenMovingBetweenInteractiveTargets() {
        let router = InputRouter()
        var feedbackCount = 0
        router.pointerHoverHandler = { feedbackCount += 1 }
        router.updateStatusBarHitFrames(
            [
                .dashboard: CGRect(x: 100, y: 100, width: 200, height: 200),
                .recenter: CGRect(x: 400, y: 100, width: 200, height: 200)
            ],
            in: CGSize(width: 1_000, height: 1_000)
        )

        router.movePointer(to: CGPoint(x: 0.2, y: 0.2), in: nil)
        router.movePointer(to: CGPoint(x: 0.5, y: 0.2), in: nil)

        XCTAssertEqual(feedbackCount, 2)
    }
}

@MainActor
private final class InputTargetSpy: InputTarget {
    var commands: [InputCommand] = []
    func handle(_ command: InputCommand) { commands.append(command) }
}
