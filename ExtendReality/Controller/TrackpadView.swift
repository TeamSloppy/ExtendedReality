@preconcurrency import CoreMotion
import Observation
import SwiftUI
import UIKit

enum ControllerInputMode: String, CaseIterable, Identifiable {
    case trackpad
    case laser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .laser: "Laser"
        }
    }

    var systemImage: String {
        switch self {
        case .trackpad: "cursorarrow"
        case .laser: "scope"
        }
    }
}

struct TrackpadView: View {
    let workspace: WorkspaceStore
    let inputRouter: InputRouter
    let mode: ControllerInputMode
    let laserController: LaserPointerController
    var onShowDashboard: () -> Void = {}
    var onShowWorkspace: () -> Void = {}

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
                    inputRouter: inputRouter,
                    laserController: laserController,
                    onShowDashboard: onShowDashboard,
                    onShowWorkspace: onShowWorkspace
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
                Text("SCROLL")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
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
                inputRouter: inputRouter,
                laserController: laserController,
                onShowDashboard: onShowDashboard,
                onShowWorkspace: onShowWorkspace
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scroll area")
        .accessibilityHint("Drag up or down with one finger to scroll the active window")
        .accessibilityIdentifier("scrollArea")
    }

    private var laserTitle: String {
        laserController.isActive ? "LASER ACTIVE" : "LASER TOUCH FALLBACK"
    }

    private var instructionText: String {
        if workspace.controlMode == .arrange {
            return "drag to move window · pinch to change distance · double tap to finish"
        }
        switch mode {
        case .trackpad:
            return "drag to move · tap to click · pinch to zoom · two fingers to scroll"
        case .laser where laserController.isActive:
            return "move the iPhone to aim · tap to click · pinch to zoom"
        case .laser:
            return "drag to point · tap to click · pinch to zoom"
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

private struct TrackpadGestureSurface: UIViewRepresentable {
    let zone: TrackpadGestureZone
    let mode: ControllerInputMode
    let workspace: WorkspaceStore
    let inputRouter: InputRouter
    let laserController: LaserPointerController
    let onShowDashboard: () -> Void
    let onShowWorkspace: () -> Void

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

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TrackpadGestureSurface
        private var previousTranslation = CGPoint.zero
        private var previousScale: CGFloat = 1
        private var resizingWindowID: UUID?

        init(parent: TrackpadGestureSurface) {
            self.parent = parent
        }

        func installGestures(on view: UIView) {
            let primaryPan = UIPanGestureRecognizer(target: self, action: #selector(handlePrimaryPan(_:)))
            primaryPan.minimumNumberOfTouches = 1
            primaryPan.maximumNumberOfTouches = 1
            primaryPan.delegate = self
            view.addGestureRecognizer(primaryPan)

            guard parent.zone == .main else { return }

            let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
            scrollPan.minimumNumberOfTouches = 2
            scrollPan.maximumNumberOfTouches = 2
            scrollPan.delegate = self
            view.addGestureRecognizer(scrollPan)

            let showDashboardSwipe = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handleShowDashboardSwipe(_:))
            )
            showDashboardSwipe.direction = .up
            showDashboardSwipe.numberOfTouchesRequired = 2
            showDashboardSwipe.delegate = self
            view.addGestureRecognizer(showDashboardSwipe)
            scrollPan.require(toFail: showDashboardSwipe)

            let showWorkspaceSwipe = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handleShowWorkspaceSwipe(_:))
            )
            showWorkspaceSwipe.direction = .down
            showWorkspaceSwipe.numberOfTouchesRequired = 3
            showWorkspaceSwipe.delegate = self
            view.addGestureRecognizer(showWorkspaceSwipe)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            tap.require(toFail: doubleTap)
            view.addGestureRecognizer(tap)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
            pinch.require(toFail: showWorkspaceSwipe)
        }

        @objc private func handleShowDashboardSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onShowDashboard()
            ControllerHaptics.navigation()
        }

        @objc private func handleShowWorkspaceSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onShowWorkspace()
            ControllerHaptics.navigation()
        }

        @objc private func handlePrimaryPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                previousTranslation = .zero
                ControllerHaptics.gestureStart()
                if parent.zone == .main,
                   parent.mode == .laser,
                   !parent.laserController.isActive {
                    movePointer(to: recognizer.location(in: view), in: view.bounds.size)
                }
                resizingWindowID = resizeTargetAtCursor()
                if let resizingWindowID {
                    parent.workspace.focus(resizingWindowID)
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
                    scroll(by: delta, in: view.bounds.size)
                } else if let resizingWindowID {
                    let normalized = normalized(delta, in: view.bounds.size)
                    parent.workspace.resizeWindow(
                        resizingWindowID,
                        normalizedDelta: normalized.dx
                    )
                    parent.inputRouter.movePointer(
                        delta: CGVector(dx: normalized.dx * 0.7, dy: 0),
                        in: resizingWindowID,
                        dispatchesToSurface: false
                    )
                } else if parent.workspace.controlMode == .arrange {
                    parent.workspace.moveActiveWindow(
                        normalizedDelta: normalized(delta, in: view.bounds.size)
                    )
                } else if parent.mode == .laser {
                    movePointer(to: recognizer.location(in: view), in: view.bounds.size)
                } else {
                    let normalized = normalized(delta, in: view.bounds.size)
                    parent.inputRouter.movePointer(
                        delta: CGVector(dx: normalized.dx * 1.35, dy: normalized.dy * 1.35),
                        in: parent.workspace.activeWindowID
                    )
                }
            case .ended, .cancelled, .failed:
                previousTranslation = .zero
                resizingWindowID = nil
            default:
                break
            }
        }

        @objc private func handleTwoFingerScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                previousTranslation = .zero
                ControllerHaptics.gestureStart()
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = CGPoint(
                    x: translation.x - previousTranslation.x,
                    y: translation.y - previousTranslation.y
                )
                previousTranslation = translation
                scroll(by: delta, in: view.bounds.size)
            case .ended, .cancelled, .failed:
                previousTranslation = .zero
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
            parent.inputRouter.pointerDown(in: parent.workspace.activeWindowID)
            parent.inputRouter.pointerUp(in: parent.workspace.activeWindowID)
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
            switch recognizer.state {
            case .began:
                previousScale = 1
                ControllerHaptics.gestureStart()
            case .changed:
                let delta = recognizer.scale / previousScale
                previousScale = recognizer.scale
                parent.workspace.zoomActiveWindow(by: delta)
            case .ended, .cancelled, .failed:
                previousScale = 1
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
                in: parent.workspace.activeWindowID
            )
        }

        private func resizeTargetAtCursor() -> UUID? {
            guard parent.zone == .main,
                  parent.workspace.controlMode == .pointer,
                  let windowID = parent.inputRouter.window(),
                  parent.inputRouter.chromeRegion(in: windowID) == .resizeHandle else { return nil }
            return windowID
        }

        private func scroll(by delta: CGPoint, in size: CGSize) {
            let normalized = normalized(delta, in: size)
            parent.inputRouter.scroll(
                delta: CGVector(dx: normalized.dx, dy: normalized.dy * 1.8),
                in: parent.workspace.activeWindowID
            )
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
            false
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
