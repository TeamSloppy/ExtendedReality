import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

@MainActor
final class SpatialPointerController {
    private(set) var isCapturing = false
    private(set) var statusText = "Pointer released"

    private unowned let store: DirectModeStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedButton: CGMouseButton?
    private var lastSourcePoint: CGPoint?
    private var activeSource: DirectCaptureSource?
    private var cursorHidden = false
    private var terminationObserver: NSObjectProtocol?

    private static let eventTag: Int64 = 0x4558_5452_4449_5245

    init(store: DirectModeStore) {
        self.store = store
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func start() {
        guard !isCapturing else { return }
        guard requestPermissions() else {
            statusText = "Accessibility and Input Monitoring are required"
            return
        }

        let eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            statusText = "Unable to create the input event tap"
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        NSCursor.hide()
        cursorHidden = true
        isCapturing = true
        statusText = "Spatial pointer captured"
    }

    func stop() {
        guard isCapturing || eventTap != nil else {
            statusText = "Pointer released"
            return
        }
        finishDragIfNeeded()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        runLoopSource = nil
        eventTap = nil
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        isCapturing = false
        activeSource = nil
        lastSourcePoint = nil
        statusText = "Pointer released"
    }

    func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ]
        for rawValue in urls {
            if let url = URL(string: rawValue) { NSWorkspace.shared.open(url) }
        }
    }

    private func requestPermissions() -> Bool {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(prompt)
        let inputMonitoring = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        return accessibility && inputMonitoring
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventTag {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if keyCode == 53 || (keyCode == 49 && flags.contains([.maskControl, .maskAlternate])) {
                stop()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel {
            guard let target = currentTarget() else { return nil }
            activate(target.source)
            let vertical = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let horizontal = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            if let injected = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
            ) {
                injected.location = target.point
                post(injected)
            }
            return nil
        }

        store.moveVirtualCursor(by: CGVector(
            dx: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
            dy: CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
        ))
        guard let target = currentTarget() else { return nil }
        activeSource = target.source
        lastSourcePoint = target.point

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = mouseButton(for: type, event: event)
            pressedButton = button
            activate(target.source)
            postMouse(type: downType(for: button), point: target.point, button: button, clickState: event.getIntegerValueField(.mouseEventClickState))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = pressedButton ?? mouseButton(for: type, event: event)
            postMouse(type: upType(for: button), point: target.point, button: button, clickState: event.getIntegerValueField(.mouseEventClickState))
            pressedButton = nil
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let button = pressedButton ?? .left
            postMouse(type: pressedButton == nil ? .mouseMoved : dragType(for: button), point: target.point, button: button, clickState: 0)
        default:
            break
        }
        return nil
    }

    private func currentTarget() -> (source: DirectCaptureSource, point: CGPoint)? {
        let canvasPoint = CGPoint(
            x: store.virtualCursor.x * store.canvasSize.width,
            y: store.virtualCursor.y * store.canvasSize.height
        )
        return store.sourcePoint(atCanvasPoint: canvasPoint)
    }

    private func activate(_ source: DirectCaptureSource) {
        guard let pid = source.ownerProcessID else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private func postMouse(
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int64
    ) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        post(event)
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    private func finishDragIfNeeded() {
        guard let button = pressedButton, let point = lastSourcePoint else { return }
        postMouse(type: upType(for: button), point: point, button: button, clickState: 1)
        pressedButton = nil
    }

    private func mouseButton(for type: CGEventType, event: CGEvent) -> CGMouseButton {
        switch type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            CGMouseButton(rawValue: UInt32(event.getIntegerValueField(.mouseEventButtonNumber))) ?? .center
        default: .left
        }
    }

    private func downType(for button: CGMouseButton) -> CGEventType {
        switch button { case .left: .leftMouseDown; case .right: .rightMouseDown; default: .otherMouseDown }
    }

    private func upType(for button: CGMouseButton) -> CGEventType {
        switch button { case .left: .leftMouseUp; case .right: .rightMouseUp; default: .otherMouseUp }
    }

    private func dragType(for button: CGMouseButton) -> CGEventType {
        switch button { case .left: .leftMouseDragged; case .right: .rightMouseDragged; default: .otherMouseDragged }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let address = UInt(bitPattern: userInfo)
        return MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else {
                return Unmanaged.passUnretained(event)
            }
            return Unmanaged<SpatialPointerController>.fromOpaque(pointer)
                .takeUnretainedValue()
                .handle(type: type, event: event)
        }
    }
}
