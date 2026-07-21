import CoreGraphics
import XCTest
@testable import ExtendReality

@MainActor
final class InputRouterTests: XCTestCase {
    func testScrollMomentumDeceleratesAndPreservesDirection() {
        var momentum = ScrollMomentum(velocity: CGPoint(x: 600, y: -1_200))

        let firstDelta = momentum.consumeFrame(duration: 1.0 / 60.0)
        let firstVelocity = momentum.velocity
        let secondDelta = momentum.consumeFrame(duration: 1.0 / 60.0)

        guard let firstDelta, let secondDelta else {
            XCTFail("Expected momentum to remain active")
            return
        }
        XCTAssertGreaterThan(firstDelta.x, 0)
        XCTAssertLessThan(firstDelta.y, 0)
        XCTAssertLessThan(abs(momentum.velocity.dy), abs(firstVelocity.dy))
        XCTAssertLessThan(abs(secondDelta.y), abs(firstDelta.y))
    }

    func testScrollMomentumStopsBelowMinimumVelocity() {
        var momentum = ScrollMomentum(velocity: CGPoint(x: 0, y: 10))

        XCTAssertFalse(momentum.isActive)
        XCTAssertNil(momentum.consumeFrame(duration: 1.0 / 60.0))
    }

    func testScrollMomentumClampsExtremeFlickVelocity() {
        let momentum = ScrollMomentum(velocity: CGPoint(x: 0, y: 20_000))

        XCTAssertEqual(hypot(momentum.velocity.dx, momentum.velocity.dy), 6_000, accuracy: 0.001)
    }

    func testHardwareMouseMappingUsesScreenCoordinates() {
        XCTAssertEqual(
            HardwareMouseMapping.pointerDelta(x: 72, y: 36),
            CGVector(dx: 0.1, dy: -0.05)
        )
        XCTAssertEqual(
            HardwareMouseMapping.scrollDelta(x: -1, y: -2),
            CGVector(dx: 0.04, dy: 0.08)
        )
    }

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

    func testSurfacePositionMovesVirtualCursorIntoSpatialWindow() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        let layout = WindowChromeLayout(
            frame: CGRect(x: 200, y: 100, width: 400, height: 500),
            in: CGSize(width: 1_000, height: 1_000)
        )
        router.register(target, for: id)
        router.updateWindowLayout(layout, for: id)

        router.movePointer(toSurfacePosition: CGPoint(x: 0.25, y: 0.75), in: id)

        XCTAssertEqual(
            router.cursor,
            layout.canvasPosition(forSurfacePosition: CGPoint(x: 0.25, y: 0.75))
        )
        XCTAssertEqual(
            target.commands,
            [.pointerMoved(normalizedPosition: CGPoint(x: 0.25, y: 0.75))]
        )
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

    func testTextInputFocusRequestsAreObservable() {
        let router = InputRouter()
        let initialRequest = router.textInputFocusRequest

        router.requestTextInputFocus()

        XCTAssertNotEqual(router.textInputFocusRequest, initialRequest)
    }

    func testPointerCoordinatesAreMappedIntoWindowSurface() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        let size = CGSize(width: 1_000, height: 500)
        let surfaceMidY = WindowChromeLayout.controlBarHeight
            + WindowChromeLayout.controlBarGap
            + (size.height - WindowChromeLayout.verticalChromeHeight) / 2
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

    func testClickFocusesWindowUnderCursorAndDispatchesToIt() throws {
        let router = InputRouter()
        let activeTarget = InputTargetSpy()
        let clickedTarget = InputTargetSpy()
        let activeID = UUID()
        let clickedID = UUID()
        var focusedWindowID: UUID?
        let clickedLayout = WindowChromeLayout(
            frame: CGRect(x: 100, y: 100, width: 300, height: 500),
            in: CGSize(width: 1_000, height: 1_000)
        )
        let cursor = CGPoint(x: 0.25, y: 0.35)
        router.register(activeTarget, for: activeID)
        router.register(clickedTarget, for: clickedID)
        router.updateWindowLayout(
            WindowChromeLayout(
                frame: CGRect(x: 600, y: 100, width: 300, height: 500),
                in: CGSize(width: 1_000, height: 1_000)
            ),
            for: activeID,
            zIndex: 2
        )
        router.updateWindowLayout(
            clickedLayout,
            for: clickedID,
            zIndex: 1
        )
        router.windowFocusHandler = { focusedWindowID = $0 }

        router.movePointer(to: cursor, in: activeID)
        activeTarget.commands.removeAll()
        router.pointerDown(in: activeID)
        router.pointerUp(in: clickedID)

        let expectedPosition = try XCTUnwrap(clickedLayout.surfacePosition(for: cursor))
        XCTAssertEqual(focusedWindowID, clickedID)
        XCTAssertTrue(activeTarget.commands.isEmpty)
        XCTAssertEqual(
            clickedTarget.commands,
            [
                .pointerDown(normalizedPosition: expectedPosition),
                .pointerUp(normalizedPosition: expectedPosition),
            ]
        )
    }

    func testClickUsesTopmostWindowWhenWindowsOverlap() {
        let router = InputRouter()
        let backID = UUID()
        let frontID = UUID()
        let layout = WindowChromeLayout(size: CGSize(width: 1_000, height: 500))
        router.updateWindowLayout(layout, for: backID, zIndex: 3)
        router.updateWindowLayout(layout, for: frontID, zIndex: 7)

        XCTAssertEqual(router.window(at: CGPoint(x: 0.5, y: 0.5)), frontID)
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

    func testVoiceAssistantDismissControlConsumesCursorClick() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let windowID = UUID()
        var dismissCount = 0
        let canvasSize = CGSize(width: 1_000, height: 1_000)
        router.register(target, for: windowID)
        router.updateWindowLayout(WindowChromeLayout(size: canvasSize), for: windowID)
        router.updateVoiceAssistantDismissHitFrame(
            CGRect(x: 400, y: 300, width: 100, height: 100),
            in: canvasSize
        )
        router.voiceAssistantDismissHandler = { dismissCount += 1 }

        router.movePointer(to: CGPoint(x: 0.45, y: 0.35), in: windowID)
        router.pointerDown(in: windowID)
        router.pointerUp(in: windowID)

        XCTAssertEqual(dismissCount, 1)
        XCTAssertTrue(target.commands.isEmpty)
    }

    func testDockConsumesClickAndLaunchesItem() {
        let router = InputRouter()
        let activeWindowID = UUID()
        let dockItemID = UUID()
        let target = InputTargetSpy()
        var receivedDockAction: DockAction?
        var receivedStatusAction: StatusBarAction?
        let hitFrame = CGRect(x: 400, y: 800, width: 200, height: 120)
        let canvasSize = CGSize(width: 1_000, height: 1_000)
        router.register(target, for: activeWindowID)
        router.updateWindowLayout(
            WindowChromeLayout(size: canvasSize),
            for: activeWindowID
        )
        router.updateStatusBarHitFrames([.dashboard: hitFrame], in: canvasSize)
        router.updateDockHitFrames([.launch(dockItemID): hitFrame], in: canvasSize)
        router.statusBarActionHandler = { receivedStatusAction = $0 }
        router.dockActionHandler = { receivedDockAction = $0 }

        router.movePointer(to: CGPoint(x: 0.5, y: 0.85), in: activeWindowID)
        target.commands.removeAll()
        router.pointerDown(in: activeWindowID)
        router.pointerUp(in: activeWindowID)

        XCTAssertEqual(receivedDockAction, .launch(dockItemID))
        XCTAssertNil(receivedStatusAction)
        XCTAssertTrue(target.commands.isEmpty)
    }

    func testDockBackActionCanBeClicked() {
        let router = InputRouter()
        var receivedDockAction: DockAction?
        let canvasSize = CGSize(width: 1_000, height: 1_000)
        router.updateDockHitFrames(
            [.dismiss: CGRect(x: 100, y: 800, width: 120, height: 120)],
            in: canvasSize
        )
        router.dockActionHandler = { receivedDockAction = $0 }

        router.movePointer(to: CGPoint(x: 0.16, y: 0.85), in: nil)
        router.pointerDown(in: nil)
        router.pointerUp(in: nil)

        XCTAssertEqual(receivedDockAction, .dismiss)
    }

    func testChromeButtonRunsActionWithoutClickingSurface() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        var receivedAction: WindowChromeAction?
        router.register(target, for: id)
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)
        router.chromeActionHandler = { _, action in receivedAction = action }

        router.movePointer(to: CGPoint(x: 0.8, y: 0.05), in: id)
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

    func testResizeHandleCanBeDetectedWithoutClickingSurface() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        router.register(target, for: id)
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)

        router.movePointer(to: CGPoint(x: 0.99, y: 0.534), in: id)
        target.commands.removeAll()
        router.pointerDown(in: id)
        router.pointerUp(in: id)

        XCTAssertEqual(router.chromeRegion(in: id), .resizeHandle)
        XCTAssertTrue(target.commands.isEmpty)
    }

    func testPointerCanMoveWithSurfaceDispatchDisabledDuringResize() {
        let router = InputRouter()
        let target = InputTargetSpy()
        let id = UUID()
        router.register(target, for: id)
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)

        router.movePointer(
            delta: CGVector(dx: 0.1, dy: 0),
            in: id,
            dispatchesToSurface: false
        )

        XCTAssertEqual(router.cursor, CGPoint(x: 0.6, y: 0.5))
        XCTAssertTrue(target.commands.isEmpty)
    }

    func testOrientationAndExpandButtonsRunChromeActions() {
        let router = InputRouter()
        let id = UUID()
        var receivedActions: [WindowChromeAction] = []
        router.updateWindowLayout(WindowChromeLayout(size: CGSize(width: 1_000, height: 500)), for: id)
        router.chromeActionHandler = { _, action in receivedActions.append(action) }

        router.movePointer(to: CGPoint(x: 0.2, y: 0.05), in: id)
        router.pointerDown(in: id)
        router.pointerUp(in: id)
        router.movePointer(to: CGPoint(x: 0.6, y: 0.05), in: id)
        router.pointerDown(in: id)
        router.pointerUp(in: id)

        XCTAssertEqual(receivedActions, [.toggleOrientation, .toggleExpanded])
    }

    func testAttachmentButtonRunsChromeAction() {
        let router = InputRouter()
        let id = UUID()
        var receivedAction: WindowChromeAction?
        router.updateWindowLayout(
            WindowChromeLayout(size: CGSize(width: 1_000, height: 500)),
            for: id
        )
        router.chromeActionHandler = { _, action in receivedAction = action }

        router.movePointer(to: CGPoint(x: 0.36, y: 0.05), in: id)
        router.pointerDown(in: id)
        router.pointerUp(in: id)

        XCTAssertEqual(receivedAction, .toggleAttachment)
    }

    func testWorkspaceLayoutStatusActionCanBeClicked() {
        let router = InputRouter()
        var receivedAction: StatusBarAction?
        router.updateStatusBarHitFrames(
            [.toggleWorkspaceLayout: CGRect(x: 300, y: 20, width: 100, height: 80)],
            in: CGSize(width: 1_000, height: 1_000)
        )
        router.statusBarActionHandler = { receivedAction = $0 }

        router.movePointer(to: CGPoint(x: 0.35, y: 0.05), in: nil)
        router.pointerDown(in: nil)
        router.pointerUp(in: nil)

        XCTAssertEqual(receivedAction, .toggleWorkspaceLayout)
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

    func testDashboardHitTestingSelectsTopmostOverlappingItem() {
        let router = InputRouter()
        let backID = UUID()
        let frontID = UUID()
        router.setDashboardPresented(true)
        router.updateDashboardLayouts([
            backID: DashboardItemInputLayout(
                center: CGPoint(x: 0.5, y: 0.5),
                size: CGSize(width: 0.4, height: 0.4),
                rotationRadians: 0,
                zIndex: 1
            ),
            frontID: DashboardItemInputLayout(
                center: CGPoint(x: 0.5, y: 0.5),
                size: CGSize(width: 0.4, height: 0.4),
                rotationRadians: .pi / 4,
                zIndex: 8
            ),
        ])

        XCTAssertEqual(router.dashboardItem(at: CGPoint(x: 0.5, y: 0.5)), frontID)
        XCTAssertNil(router.dashboardItem(at: CGPoint(x: 0.9, y: 0.9)))
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

    func testTopmostSpatialPanelReceivesLocalPointerAndFocus() {
        let router = InputRouter()
        let windowID = UUID()
        let backTarget = InputTargetSpy()
        let frontTarget = InputTargetSpy()
        let canvas = CGSize(width: 1_000, height: 1_000)
        router.updateWindowLayout(WindowChromeLayout(size: canvas), for: windowID, zIndex: 4)
        router.register(backTarget, for: "back", in: windowID)
        router.register(frontTarget, for: "front", in: windowID)
        router.updatePanelLayouts([
            SpatialPanelInputLayout(
                windowID: windowID,
                panelID: "back",
                frame: CGRect(x: 200, y: 200, width: 400, height: 400),
                canvasSize: canvas,
                appZIndex: 4,
                layer: 0,
                depth: 1.2
            ),
            SpatialPanelInputLayout(
                windowID: windowID,
                panelID: "front",
                frame: CGRect(x: 300, y: 300, width: 400, height: 400),
                canvasSize: canvas,
                appZIndex: 4,
                layer: 1,
                depth: 0.9
            ),
        ])
        var focused: SpatialPanelID?
        router.panelFocusHandler = { _, panelID in focused = panelID }

        router.movePointer(to: CGPoint(x: 0.5, y: 0.5), in: windowID)
        frontTarget.commands.removeAll()
        router.pointerDown(in: windowID)
        router.pointerUp(in: windowID)

        XCTAssertEqual(focused, "front")
        XCTAssertTrue(backTarget.commands.isEmpty)
        XCTAssertEqual(
            frontTarget.commands,
            [
                .pointerDown(normalizedPosition: CGPoint(x: 0.5, y: 0.5)),
                .pointerUp(normalizedPosition: CGPoint(x: 0.5, y: 0.5)),
            ]
        )
    }
}

@MainActor
private final class InputTargetSpy: InputTarget {
    var commands: [InputCommand] = []
    func handle(_ command: InputCommand) { commands.append(command) }
}
