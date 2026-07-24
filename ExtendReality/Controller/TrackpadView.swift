@preconcurrency import CoreMotion
import Observation
import SwiftUI
import UIKit

enum ControllerInputMode: String, CaseIterable, Identifiable {
    case trackpad
    case laser
    case hands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .laser: "Laser"
        case .hands: "Hands"
        }
    }

    var systemImage: String {
        switch self {
        case .trackpad: "cursorarrow"
        case .laser: "scope"
        case .hands: "hand.point.up.left.fill"
        }
    }
}

private final class ThreeFingerPinchGestureRecognizer: UIGestureRecognizer {
    private var trackedTouches: [ObjectIdentifier: UITouch] = [:]
    private var initialSpread: CGFloat?
    private let activationScaleDelta: CGFloat = 0.12

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            trackedTouches[ObjectIdentifier(touch)] = touch
        }
        guard trackedTouches.count <= 3 else {
            state = .failed
            return
        }
        if trackedTouches.count == 3 {
            initialSpread = spread()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible,
              trackedTouches.count == 3,
              let initialSpread,
              initialSpread > 0 else { return }
        let scale = spread() / initialSpread
        if abs(scale - 1) >= activationScaleDelta {
            state = .ended
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        for touch in touches {
            trackedTouches.removeValue(forKey: ObjectIdentifier(touch))
        }
        if state == .possible {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll()
        initialSpread = nil
    }

    private func spread() -> CGFloat {
        guard let view, trackedTouches.count == 3 else { return 0 }
        let points = trackedTouches.values.map { $0.location(in: view) }
        let center = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x / 3, y: partial.y + point.y / 3)
        }
        return points.reduce(0) { partial, point in
            partial + hypot(point.x - center.x, point.y - center.y) / 3
        }
    }
}

struct TrackpadView: View {
    let workspace: WorkspaceStore
    let dashboard: DashboardStore
    let inputRouter: InputRouter
    let mode: ControllerInputMode
    let laserController: LaserPointerController
    var onShowDashboard: () -> Void = {}
    var onCenterWindow: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            mainArea

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 1)

            scrollArea
                .frame(width: 58)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.11), lineWidth: 1)
        }
    }

    private var mainArea: some View {
        GeometryReader { proxy in
            ZStack {
                DottedTrackpadGrid()

                Image(systemName: mode == .laser ? "scope" : "circle.circle")
                    .font(.system(size: mode == .laser ? 38 : 28, weight: .medium))
                    .foregroundStyle(mode == .laser ? .orange : .white.opacity(0.22))
                    .position(cursorPosition(in: proxy.size))
                    .animation(.linear(duration: 0.04), value: inputRouter.cursor)

                VStack {
                    Spacer()
                    VStack(spacing: 7) {
                        Text(mode == .laser ? laserTitle : "TRACKPAD")
                            .font(.caption.weight(.bold))
                            .tracking(1.6)
                        Text(instructionText)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .allowsHitTesting(false)

                TrackpadGestureSurface(
                    zone: .main,
                    mode: mode,
                    workspace: workspace,
                    dashboard: dashboard,
                    inputRouter: inputRouter,
                    laserController: laserController,
                    onShowDashboard: onShowDashboard,
                    onCenterWindow: onCenterWindow
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .laser ? "Laser control area" : "Trackpad control area")
        .accessibilityHint(instructionText)
        .accessibilityIdentifier("trackpad")
    }

    private var scrollArea: some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)

            VStack(spacing: 12) {
                Image(systemName: "chevron.up")
                Spacer()
                Image(systemName: "arrow.up.and.down")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 3) {
                    Text(workspace.controlMode == .arrange ? "SCROLL" : "1F / 2F")
                    Text(workspace.controlMode == .arrange ? "DEPTH" : "SCROLL")
                }
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                Spacer()
                Image(systemName: "chevron.down")
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 18)
            .allowsHitTesting(false)

            TrackpadGestureSurface(
                zone: .scroll,
                mode: mode,
                workspace: workspace,
                dashboard: dashboard,
                inputRouter: inputRouter,
                laserController: laserController,
                onShowDashboard: onShowDashboard,
                onCenterWindow: onCenterWindow
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scroll area")
        .accessibilityHint(
            workspace.controlMode == .arrange
                ? "Scroll to change window distance."
                : "Scroll with one or two fingers in the active window."
        )
        .accessibilityIdentifier("scrollArea")
    }

    private var laserTitle: String {
        laserController.isActive ? "LASER ACTIVE" : "LASER TOUCH FALLBACK"
    }

    private var instructionText: String {
        if workspace.isDashboardPresented || workspace.presentationMode == .widgets {
            if workspace.controlMode == .arrange {
                return "drag a card to move · pinch to resize · double tap to finish"
            }
            return workspace.isDashboardPresented
                ? "move to an app · tap to open · pinch with 3 fingers to close"
                : "move to a widget · 3F up for windows · 3F pinch for dashboard"
        }
        if workspace.controlMode == .arrange {
            if workspace.layoutMode == .stack {
                return "drag to reorder or move stack · pinch to resize"
            }
            return "drag to move window · pinch to resize · double tap to finish"
        }
        switch mode {
        case .trackpad:
            return "drag pointer · tap click · pinch in app · 2F scroll · 3F navigate"
        case .laser where laserController.isActive:
            return "move iPhone to aim · tap click · pinch in app"
        case .laser:
            return "drag to point · tap click · pinch in app"
        case .hands:
            return "point to aim · pinch to click and drag"
        }
    }

    private func cursorPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: inputRouter.cursor.x * size.width,
            y: inputRouter.cursor.y * size.height
        )
    }
}

private struct DottedTrackpadGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            var x = spacing / 2
            while x < size.width {
                var y = spacing / 2
                while y < size.height {
                    let dot = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(.orange.opacity(0.13)))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
@Observable
final class LaserPointerController {
    private(set) var isActive = false
    private(set) var isAvailable: Bool

    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private var referenceAttitude: CMAttitude?
    @ObservationIgnored private var anchorCursor = CGPoint(x: 0.5, y: 0.5)
    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private weak var inputRouter: InputRouter?

    init() {
        isAvailable = motionManager.isDeviceMotionAvailable
    }

    func start(workspace: WorkspaceStore, inputRouter: InputRouter) {
        self.workspace = workspace
        self.inputRouter = inputRouter
        isAvailable = motionManager.isDeviceMotionAvailable
        guard isAvailable else {
            isActive = false
            return
        }

        anchorCursor = inputRouter.cursor
        referenceAttitude = nil
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated {
                self?.consume(motion.attitude)
            }
        }
        isActive = true
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        referenceAttitude = nil
        isActive = false
    }

    func recenter() {
        anchorCursor = inputRouter?.cursor ?? CGPoint(x: 0.5, y: 0.5)
        referenceAttitude = nil
        ControllerHaptics.selection()
    }

    private func consume(_ attitude: CMAttitude) {
        guard let workspace, let inputRouter else { return }
        guard let referenceAttitude else {
            self.referenceAttitude = attitude.copy() as? CMAttitude
            return
        }
        guard let relative = attitude.copy() as? CMAttitude else { return }
        relative.multiply(byInverseOf: referenceAttitude)

        let horizontalRange = 35.0 * Double.pi / 180.0
        let verticalRange = 26.0 * Double.pi / 180.0
        inputRouter.movePointer(
            to: CGPoint(
                x: anchorCursor.x + relative.yaw / horizontalRange,
                y: anchorCursor.y - relative.pitch / verticalRange
            ),
            in: workspace.activeWindowID
        )
    }
}

private enum TrackpadGestureZone {
    case main
    case scroll
}

private struct WindowResizeTarget {
    let windowID: UUID
    let edge: WindowResizeEdge
}

struct ScrollMomentum: Equatable {
    static let decelerationRate = Double(UIScrollView.DecelerationRate.normal.rawValue)
    static let maximumVelocity: CGFloat = 6_000
    static let stoppingVelocity: CGFloat = 18

    private(set) var velocity: CGVector

    init(velocity: CGPoint) {
        let magnitude = hypot(velocity.x, velocity.y)
        let scale = magnitude > Self.maximumVelocity ? Self.maximumVelocity / magnitude : 1
        self.velocity = CGVector(dx: velocity.x * scale, dy: velocity.y * scale)
    }

    var isActive: Bool {
        hypot(velocity.dx, velocity.dy) >= Self.stoppingVelocity
    }

    mutating func consumeFrame(duration: TimeInterval) -> CGPoint? {
        guard isActive, duration > 0 else { return nil }
        let duration = min(duration, 1.0 / 30.0)
        let decay = pow(Self.decelerationRate, duration * 1_000)
        let decayConstant = 1_000 * log(Self.decelerationRate)
        let distanceScale = (decay - 1) / decayConstant
        let delta = CGPoint(
            x: Double(velocity.dx) * distanceScale,
            y: Double(velocity.dy) * distanceScale
        )
        velocity = CGVector(
            dx: Double(velocity.dx) * decay,
            dy: Double(velocity.dy) * decay
        )
        return delta
    }
}

private struct TrackpadGestureSurface: UIViewRepresentable {
    let zone: TrackpadGestureZone
    let mode: ControllerInputMode
    let workspace: WorkspaceStore
    let dashboard: DashboardStore
    let inputRouter: InputRouter
    let laserController: LaserPointerController
    let onShowDashboard: () -> Void
    let onCenterWindow: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopScrollMomentum()
        coordinator.parent.inputRouter.endWindowResize()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TrackpadGestureSurface
        private var previousTranslation = CGPoint.zero
        private var previousScale: CGFloat = 1
        private var resizeTarget: WindowResizeTarget?
        private var scrollMomentum: ScrollMomentum?
        private var scrollDisplayLink: CADisplayLink?
        private var scrollFrameTimestamp: CFTimeInterval?
        private var scrollMomentumTargetWindowID: UUID?
        private var scrollMomentumSurfaceSize = CGSize.zero

        init(parent: TrackpadGestureSurface) {
            self.parent = parent
        }

        func installGestures(on view: UIView) {
            let primaryPan = UIPanGestureRecognizer(target: self, action: #selector(handlePrimaryPan(_:)))
            primaryPan.minimumNumberOfTouches = 1
            primaryPan.maximumNumberOfTouches = 1
            primaryPan.delegate = self
            view.addGestureRecognizer(primaryPan)

            let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
            scrollPan.minimumNumberOfTouches = 2
            scrollPan.maximumNumberOfTouches = 2
            scrollPan.delegate = self
            view.addGestureRecognizer(scrollPan)

            if parent.zone == .scroll { return }

            let showWidgetsSwipe = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handleShowWidgetsSwipe(_:))
            )
            showWidgetsSwipe.direction = .down
            showWidgetsSwipe.numberOfTouchesRequired = 3
            showWidgetsSwipe.delegate = self
            view.addGestureRecognizer(showWidgetsSwipe)
            let showWindowsSwipe = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handleShowWindowsSwipe(_:))
            )
            showWindowsSwipe.direction = .up
            showWindowsSwipe.numberOfTouchesRequired = 3
            showWindowsSwipe.delegate = self
            view.addGestureRecognizer(showWindowsSwipe)

            let dashboardPinch = ThreeFingerPinchGestureRecognizer(
                target: self,
                action: #selector(handleDashboardPinch(_:))
            )
            dashboardPinch.delegate = self
            view.addGestureRecognizer(dashboardPinch)

            let previousWindowSwipe = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handlePreviousWindowSwipe(_:))
            )
            previousWindowSwipe.direction = .right
            previousWindowSwipe.numberOfTouchesRequired = 3
            previousWindowSwipe.delegate = self
            view.addGestureRecognizer(previousWindowSwipe)

            let nextWindowSwipe = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handleNextWindowSwipe(_:))
            )
            nextWindowSwipe.direction = .left
            nextWindowSwipe.numberOfTouchesRequired = 3
            nextWindowSwipe.delegate = self
            view.addGestureRecognizer(nextWindowSwipe)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            tap.require(toFail: doubleTap)
            view.addGestureRecognizer(tap)

            let centerDoubleTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleCenterDoubleTap(_:))
            )
            centerDoubleTap.numberOfTapsRequired = 2
            centerDoubleTap.numberOfTouchesRequired = 2
            centerDoubleTap.delegate = self
            view.addGestureRecognizer(centerDoubleTap)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
        }

        @objc private func handleShowWidgetsSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.workspace.showWidgets()
            parent.inputRouter.setDashboardPresented(true)
            ControllerHaptics.navigation()
        }

        @objc private func handleShowWindowsSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.workspace.showWindows()
            parent.inputRouter.setDashboardPresented(false)
            ControllerHaptics.navigation()
        }

        @objc private func handleDashboardPinch(_ recognizer: ThreeFingerPinchGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onShowDashboard()
            ControllerHaptics.navigation()
        }

        @objc private func handlePreviousWindowSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended,
                  parent.workspace.presentationMode == .windows,
                  !parent.workspace.isDashboardPresented else { return }
            parent.workspace.focusAdjacentWindow(by: -1)
            ControllerHaptics.navigation()
        }

        @objc private func handleNextWindowSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended,
                  parent.workspace.presentationMode == .windows,
                  !parent.workspace.isDashboardPresented else { return }
            parent.workspace.focusAdjacentWindow(by: 1)
            ControllerHaptics.navigation()
        }

        @objc private func handleCenterDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  parent.workspace.presentationMode == .windows,
                  !parent.workspace.isDashboardPresented,
                  parent.workspace.activeWindowID != nil else { return }
            parent.onCenterWindow()
            ControllerHaptics.navigation()
        }

        @objc private func handlePrimaryPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                stopScrollMomentum()
                parent.inputRouter.endWindowResize()
                previousTranslation = .zero
                ControllerHaptics.gestureStart()
                if parent.zone == .scroll { return }
                if parent.zone == .main,
                   parent.mode == .laser,
                   !parent.laserController.isActive {
                    movePointer(to: recognizer.location(in: view), in: view.bounds.size)
                }
                if isDashboardSurfacePresented,
                   parent.workspace.controlMode == .arrange,
                   let itemID = parent.inputRouter.dashboardItem() {
                    parent.dashboard.beginArranging(itemID)
                    ControllerHaptics.selection()
                } else {
                    parent.workspace.beginActiveWindowMove()
                    resizeTarget = resizeTargetAtCursor()
                }
                if let resizeTarget {
                    parent.workspace.focus(resizeTarget.windowID)
                    ControllerHaptics.selection()
                }
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = CGPoint(
                    x: translation.x - previousTranslation.x,
                    y: translation.y - previousTranslation.y
                )
                previousTranslation = translation

                if parent.zone == .scroll {
                    routeScroll(by: delta, in: view.bounds.size)
                } else if isDashboardSurfacePresented,
                   parent.workspace.controlMode == .arrange {
                    let normalizedDelta = normalized(delta, in: view.bounds.size)
                    parent.dashboard.moveSelected(normalizedDelta: normalizedDelta)
                    parent.inputRouter.movePointer(
                        delta: normalizedDelta,
                        in: nil,
                        dispatchesToSurface: false
                    )
                } else if let resizeTarget {
                    let normalized = normalized(delta, in: view.bounds.size)
                    parent.workspace.resizeWindow(
                        resizeTarget.windowID,
                        normalizedDelta: resizeTarget.edge.resizeDelta(from: normalized)
                    )
                    parent.inputRouter.movePointer(
                        delta: CGVector(
                            dx: normalized.dx * 0.7,
                            dy: normalized.dy * 0.7
                        ),
                        in: resizeTarget.windowID,
                        dispatchesToSurface: false
                    )
                } else if parent.workspace.controlMode == .arrange {
                    let reorderCount = parent.workspace.moveActiveWindow(
                        normalizedDelta: normalized(delta, in: view.bounds.size)
                    )
                    for _ in 0 ..< reorderCount {
                        ControllerHaptics.selection()
                    }
                } else if parent.mode == .laser {
                    movePointer(to: recognizer.location(in: view), in: view.bounds.size)
                } else {
                    let normalized = normalized(delta, in: view.bounds.size)
                    parent.inputRouter.movePointer(
                        delta: CGVector(dx: normalized.dx * 1.35, dy: normalized.dy * 1.35),
                        in: parent.workspace.activeWindowID
                    )
                }
            case .ended:
                previousTranslation = .zero
                if parent.zone == .scroll {
                    if parent.workspace.controlMode == .pointer {
                        startScrollMomentum(
                            velocity: recognizer.velocity(in: view),
                            surfaceSize: view.bounds.size
                        )
                    }
                    return
                }
                resizeTarget = nil
                parent.inputRouter.endWindowResize()
                if isDashboardSurfacePresented {
                    parent.dashboard.endArranging()
                } else {
                    parent.workspace.endActiveWindowMove()
                }
            case .cancelled, .failed:
                previousTranslation = .zero
                stopScrollMomentum()
                resizeTarget = nil
                parent.inputRouter.endWindowResize()
                if isDashboardSurfacePresented {
                    parent.dashboard.endArranging()
                } else if parent.zone == .main {
                    parent.workspace.endActiveWindowMove()
                }
            default:
                break
            }
        }

        @objc private func handleTwoFingerScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                stopScrollMomentum()
                previousTranslation = .zero
                ControllerHaptics.gestureStart()
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = CGPoint(
                    x: translation.x - previousTranslation.x,
                    y: translation.y - previousTranslation.y
                )
                previousTranslation = translation
                routeScroll(by: delta, in: view.bounds.size)
            case .ended:
                previousTranslation = .zero
                if parent.workspace.controlMode == .pointer {
                    startScrollMomentum(
                        velocity: recognizer.velocity(in: view),
                        surfaceSize: view.bounds.size
                    )
                }
            case .cancelled, .failed:
                previousTranslation = .zero
                stopScrollMomentum()
            default:
                break
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.workspace.controlMode == .pointer else { return }
            if parent.mode == .laser,
               !parent.laserController.isActive,
               let view = recognizer.view {
                movePointer(to: recognizer.location(in: view), in: view.bounds.size)
            }
            parent.inputRouter.pointerDown(in: targetWindowID)
            parent.inputRouter.pointerUp(in: targetWindowID)
            ControllerHaptics.click()
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            if parent.workspace.controlMode == .arrange {
                parent.workspace.controlMode = .pointer
                ControllerHaptics.navigation()
                return
            }

            guard let windowID = parent.workspace.activeWindowID,
                  parent.inputRouter.chromeRegion(in: windowID) == .moveHandle else { return }
            parent.workspace.focus(windowID)
            parent.workspace.controlMode = .arrange
            ControllerHaptics.navigation()
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.numberOfTouches < 3 else { return }
            switch recognizer.state {
            case .began:
                previousScale = 1
                if isDashboardSurfacePresented,
                   parent.workspace.controlMode == .arrange,
                   let itemID = parent.inputRouter.dashboardItem() {
                    parent.dashboard.beginArranging(itemID)
                }
                ControllerHaptics.gestureStart()
            case .changed:
                let delta = recognizer.scale / previousScale
                previousScale = recognizer.scale
                if isDashboardSurfacePresented,
                   parent.workspace.controlMode == .arrange {
                    parent.dashboard.scaleSelected(by: delta)
                } else if parent.workspace.presentationMode == .windows,
                          !parent.workspace.isDashboardPresented,
                          parent.workspace.controlMode == .arrange {
                    parent.workspace.scaleActiveWindow(by: delta)
                } else if parent.workspace.presentationMode == .windows,
                          !parent.workspace.isDashboardPresented {
                    parent.inputRouter.magnify(by: delta, in: targetWindowID)
                }
            case .ended, .cancelled, .failed:
                previousScale = 1
                if isDashboardSurfacePresented {
                    parent.dashboard.endArranging()
                }
            default:
                break
            }
        }

        private func movePointer(to point: CGPoint, in size: CGSize) {
            parent.inputRouter.movePointer(
                to: CGPoint(
                    x: point.x / max(size.width, 1),
                    y: point.y / max(size.height, 1)
                ),
                in: targetWindowID
            )
        }

        private func resizeTargetAtCursor() -> WindowResizeTarget? {
            guard parent.zone == .main,
                  parent.workspace.presentationMode == .windows,
                  !parent.workspace.isDashboardPresented,
                  parent.workspace.controlMode == .pointer,
                  let windowID = parent.inputRouter.window(),
                  let hover = parent.inputRouter.beginWindowResize(in: windowID) else { return nil }
            return WindowResizeTarget(windowID: windowID, edge: hover.edge)
        }

        private func scroll(by delta: CGPoint, in size: CGSize) {
            scroll(by: delta, in: size, windowID: targetWindowID)
        }

        private func routeScroll(by delta: CGPoint, in size: CGSize) {
            if parent.workspace.presentationMode == .windows,
               !parent.workspace.isDashboardPresented,
               parent.workspace.controlMode == .arrange,
               let windowID = parent.workspace.activeWindowID {
                let normalizedDelta = delta.y / max(size.height, 1)
                parent.workspace.adjustWindowDistance(
                    windowID,
                    by: Double(normalizedDelta) * 1.6
                )
                return
            }
            scroll(by: delta, in: size)
        }

        private func scroll(by delta: CGPoint, in size: CGSize, windowID: UUID?) {
            let normalized = normalized(delta, in: size)
            parent.inputRouter.scroll(
                delta: CGVector(dx: normalized.dx, dy: normalized.dy * 1.8),
                in: windowID
            )
        }

        private func startScrollMomentum(velocity: CGPoint, surfaceSize: CGSize) {
            stopScrollMomentum()
            let momentum = ScrollMomentum(velocity: velocity)
            guard momentum.isActive else { return }
            scrollMomentum = momentum
            scrollMomentumTargetWindowID = targetWindowID
            scrollMomentumSurfaceSize = surfaceSize
            let displayLink = CADisplayLink(target: self, selector: #selector(advanceScrollMomentum(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30,
                maximum: 120,
                preferred: 120
            )
            displayLink.add(to: .main, forMode: .common)
            scrollDisplayLink = displayLink
        }

        @objc private func advanceScrollMomentum(_ displayLink: CADisplayLink) {
            guard targetWindowID == scrollMomentumTargetWindowID,
                  parent.workspace.controlMode == .pointer,
                  !parent.workspace.isAppSwitcherPresented,
                  var momentum = scrollMomentum else {
                stopScrollMomentum()
                return
            }
            guard let scrollFrameTimestamp else {
                self.scrollFrameTimestamp = displayLink.timestamp
                return
            }
            self.scrollFrameTimestamp = displayLink.timestamp
            guard let delta = momentum.consumeFrame(
                duration: displayLink.timestamp - scrollFrameTimestamp
            ) else {
                stopScrollMomentum()
                return
            }
            scrollMomentum = momentum
            scroll(
                by: delta,
                in: scrollMomentumSurfaceSize,
                windowID: scrollMomentumTargetWindowID
            )
        }

        func stopScrollMomentum() {
            scrollDisplayLink?.invalidate()
            scrollDisplayLink = nil
            scrollMomentum = nil
            scrollFrameTimestamp = nil
            scrollMomentumTargetWindowID = nil
            scrollMomentumSurfaceSize = .zero
        }

        private var targetWindowID: UUID? {
            isDashboardSurfacePresented
                ? nil
                : parent.workspace.activeWindowID
        }

        private var isDashboardSurfacePresented: Bool {
            parent.workspace.isDashboardPresented || parent.workspace.presentationMode == .widgets
        }

        private func normalized(_ delta: CGPoint, in size: CGSize) -> CGVector {
            CGVector(
                dx: delta.x / max(size.width, 1),
                dy: delta.y / max(size.height, 1)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is ThreeFingerPinchGestureRecognizer
                || otherGestureRecognizer is ThreeFingerPinchGestureRecognizer
        }
    }
}

@MainActor
enum ControllerHaptics {
    static func hover() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func click() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
    }

    static func gestureStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)
    }

    static func navigation() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.65)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

#if DEBUG
#Preview("Trackpad") {
    let environment = AppEnvironment.preview()
    TrackpadView(
        workspace: environment.workspace,
        dashboard: environment.dashboard,
        inputRouter: environment.inputRouter,
        mode: .trackpad,
        laserController: LaserPointerController()
    )
    .previewEnvironment(environment)
    .padding()
    .frame(width: 390, height: 560)
    .preferredColorScheme(.dark)
}
#endif
