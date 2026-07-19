@preconcurrency import GameController
import CoreGraphics
import Foundation
import Observation

struct HardwareMouseMapping {
    static let pointerSensitivity: CGFloat = 1 / 720
    static let scrollSensitivity: CGFloat = 0.04

    static func pointerDelta(x: Float, y: Float) -> CGVector {
        CGVector(
            dx: CGFloat(x) * pointerSensitivity,
            dy: -CGFloat(y) * pointerSensitivity
        )
    }

    static func scrollDelta(x: Float, y: Float) -> CGVector {
        CGVector(
            dx: -CGFloat(x) * scrollSensitivity,
            dy: -CGFloat(y) * scrollSensitivity
        )
    }
}

@MainActor
@Observable
final class HardwareMouseInput {
    private(set) var isMouseConnected = false
    private(set) var isCaptureEnabled = false
    private(set) var mouseName: String?

    @ObservationIgnored var capturePreferenceDidChange: (() -> Void)?
    @ObservationIgnored private let inputRouter: InputRouter
    @ObservationIgnored private let activeWindowID: () -> UUID?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var boundMice: [ObjectIdentifier: GCMouse] = [:]
    @ObservationIgnored private var isLeftButtonPressed = false

    init(
        inputRouter: InputRouter,
        activeWindowID: @escaping () -> UUID?,
        startsMonitoring: Bool = true
    ) {
        self.inputRouter = inputRouter
        self.activeWindowID = activeWindowID
        guard startsMonitoring else { return }
        startMonitoring()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func toggleCapture() {
        setCaptureEnabled(!isCaptureEnabled)
    }

    func setCaptureEnabled(_ isEnabled: Bool) {
        let resolvedValue = isEnabled && isMouseConnected
        guard resolvedValue != isCaptureEnabled else { return }

        if !resolvedValue, isLeftButtonPressed {
            inputRouter.pointerUp(in: activeWindowID())
            isLeftButtonPressed = false
        }

        isCaptureEnabled = resolvedValue
        if resolvedValue {
            inputRouter.resetCursor()
        }
        capturePreferenceDidChange?()
    }

    private func startMonitoring() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .GCMouseDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let mouse = notification.object as? GCMouse else { return }
                Task { @MainActor [weak self] in
                    self?.bind(mouse)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .GCMouseDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let mouse = notification.object as? GCMouse else { return }
                Task { @MainActor [weak self] in
                    self?.unbind(mouse)
                }
            }
        )

        for mouse in GCMouse.mice() {
            bind(mouse)
        }
        updateConnectionState()
    }

    private func bind(_ mouse: GCMouse) {
        let identifier = ObjectIdentifier(mouse)
        guard boundMice[identifier] == nil, let mouseInput = mouse.mouseInput else { return }

        mouse.handlerQueue = .main
        mouseInput.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            Task { @MainActor [weak self] in
                self?.handleMovement(x: deltaX, y: deltaY)
            }
        }
        mouseInput.leftButton.pressedChangedHandler = { [weak self] _, _, isPressed in
            Task { @MainActor [weak self] in
                self?.handleLeftButton(isPressed: isPressed)
            }
        }
        mouseInput.rightButton?.pressedChangedHandler = { [weak self] _, _, isPressed in
            guard isPressed else { return }
            Task { @MainActor [weak self] in
                self?.handleBackButton()
            }
        }
        mouseInput.scroll.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor [weak self] in
                self?.handleScroll(x: xValue, y: yValue)
            }
        }

        boundMice[identifier] = mouse
        updateConnectionState(preferredMouse: mouse)
    }

    private func unbind(_ mouse: GCMouse) {
        if let mouseInput = mouse.mouseInput {
            mouseInput.mouseMovedHandler = nil
            mouseInput.leftButton.pressedChangedHandler = nil
            mouseInput.rightButton?.pressedChangedHandler = nil
            mouseInput.scroll.valueChangedHandler = nil
        }
        boundMice.removeValue(forKey: ObjectIdentifier(mouse))
        updateConnectionState()
    }

    private func updateConnectionState(preferredMouse: GCMouse? = nil) {
        isMouseConnected = !boundMice.isEmpty
        mouseName = preferredMouse?.vendorName ?? boundMice.values.first?.vendorName
        if !isMouseConnected {
            setCaptureEnabled(false)
        }
    }

    private func handleMovement(x: Float, y: Float) {
        guard isCaptureEnabled else { return }
        inputRouter.movePointer(
            delta: HardwareMouseMapping.pointerDelta(x: x, y: y),
            in: activeWindowID()
        )
    }

    private func handleLeftButton(isPressed: Bool) {
        guard isCaptureEnabled, isPressed != isLeftButtonPressed else { return }
        isLeftButtonPressed = isPressed
        if isPressed {
            inputRouter.pointerDown(in: activeWindowID())
        } else {
            inputRouter.pointerUp(in: activeWindowID())
        }
    }

    private func handleBackButton() {
        guard isCaptureEnabled else { return }
        inputRouter.back(in: activeWindowID())
    }

    private func handleScroll(x: Float, y: Float) {
        guard isCaptureEnabled else { return }
        inputRouter.scroll(
            delta: HardwareMouseMapping.scrollDelta(x: x, y: y),
            in: activeWindowID()
        )
    }
}
