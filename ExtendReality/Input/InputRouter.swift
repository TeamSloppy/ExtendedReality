import CoreGraphics
import Foundation
import Observation

enum WindowChromeRegion: Equatable {
    case outside
    case surface
    case titleBar
    case moveHandle
    case moveFartherButton
    case moveCloserButton
    case minimizeButton
    case closeButton
}

enum WindowChromeAction: Equatable {
    case moveFarther
    case moveCloser
    case minimize
    case close
}

struct WindowChromeLayout: Equatable {
    static let titleBarHeight: CGFloat = 38
    static let ornamentHeight: CGFloat = 58
    static let controlWidth: CGFloat = 58

    let frame: CGRect
    let canvasSize: CGSize
    let rotationRadians: Double

    init(size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        canvasSize = size
        rotationRadians = 0
    }

    init(frame: CGRect, in canvasSize: CGSize, rotationRadians: Double = 0) {
        self.frame = frame
        self.canvasSize = canvasSize
        self.rotationRadians = rotationRadians
    }

    func region(at normalizedPosition: CGPoint) -> WindowChromeRegion {
        guard let point = localPoint(for: normalizedPosition) else { return .outside }

        if surfaceRect.contains(point) {
            return .surface
        }
        if point.y < Self.titleBarHeight {
            return .titleBar
        }
        if point.x < Self.controlWidth {
            return .closeButton
        }
        if point.x < Self.controlWidth * 2 {
            return .moveFartherButton
        }
        if point.x >= max(Self.controlWidth, frame.width - Self.controlWidth) {
            return .minimizeButton
        }
        if point.x >= max(Self.controlWidth * 2, frame.width - Self.controlWidth * 2) {
            return .moveCloserButton
        }
        return .moveHandle
    }

    func surfacePosition(for normalizedPosition: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard let point = localPoint(for: normalizedPosition, clamped: clamped) else { return nil }
        guard clamped || surfaceRect.contains(point) else { return nil }

        return CGPoint(
            x: ((point.x - surfaceRect.minX) / max(surfaceRect.width, 1)).clamped(to: 0 ... 1),
            y: ((point.y - surfaceRect.minY) / max(surfaceRect.height, 1)).clamped(to: 0 ... 1)
        )
    }

    private var surfaceRect: CGRect {
        CGRect(
            x: 0,
            y: Self.titleBarHeight,
            width: frame.width,
            height: max(frame.height - Self.titleBarHeight - Self.ornamentHeight, 1)
        )
    }

    private func localPoint(for position: CGPoint, clamped: Bool = false) -> CGPoint? {
        let canvasPoint = CGPoint(
            x: position.x * max(canvasSize.width, 1),
            y: position.y * max(canvasSize.height, 1)
        )
        let unrotatedPoint = canvasPoint.rotated(around: frame.center, by: -rotationRadians)
        var point = CGPoint(x: unrotatedPoint.x - frame.minX, y: unrotatedPoint.y - frame.minY)

        if clamped {
            point.x = point.x.clamped(to: 0 ... max(frame.width, 0))
            point.y = point.y.clamped(to: 0 ... max(frame.height, 0))
            return point
        }

        guard CGRect(origin: .zero, size: frame.size).contains(point) else { return nil }
        return point
    }
}

enum StatusBarAction: Hashable {
    case dashboard
    case pointerMode
    case arrangeMode
    case recenter
}

enum PointerHoverTarget: Equatable {
    case statusBar(StatusBarAction)
    case dashboard(UUID)
    case appSwitcher(UUID)
    case windowChrome(UUID, WindowChromeRegion)
}

enum InputCommand: Sendable, Equatable {
    case pointerMoved(normalizedPosition: CGPoint)
    case pointerDown(normalizedPosition: CGPoint)
    case pointerUp(normalizedPosition: CGPoint)
    case scroll(normalizedDelta: CGVector)
    case insertText(String)
    case back
    case media(MediaCommand)
}

enum MediaCommand: Sendable, Equatable {
    case play
    case pause
    case togglePlayback
    case seek(seconds: Double)
}

@MainActor
protocol InputTarget: AnyObject {
    func handle(_ command: InputCommand)
}

@MainActor
private final class WeakInputTarget {
    weak var value: (any InputTarget)?

    init(_ value: any InputTarget) {
        self.value = value
    }
}

@MainActor
@Observable
final class InputRouter {
    private(set) var cursor = CGPoint(x: 0.5, y: 0.5)
    private(set) var isCursorVisible = true
    @ObservationIgnored private let cursorInactivityDuration: Duration
    @ObservationIgnored private var cursorInactivityTask: Task<Void, Never>?
    @ObservationIgnored private var hoveredTarget: PointerHoverTarget?
    @ObservationIgnored private var targets: [UUID: WeakInputTarget] = [:]
    @ObservationIgnored private var windowLayouts: [UUID: WindowChromeLayout] = [:]
    @ObservationIgnored private var pressedRegions: [UUID: WindowChromeRegion] = [:]
    @ObservationIgnored private var dashboardHitFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var pressedDashboardItemID: UUID?
    @ObservationIgnored private var statusBarHitFrames: [StatusBarAction: CGRect] = [:]
    @ObservationIgnored private var pressedStatusBarAction: StatusBarAction?
    @ObservationIgnored private var appSwitcherHitFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var pressedAppSwitcherWindowID: UUID?
    @ObservationIgnored private var isAppSwitcherPresented = false
    @ObservationIgnored var chromeActionHandler: ((UUID, WindowChromeAction) -> Void)?
    @ObservationIgnored var dashboardActionHandler: ((UUID) -> Void)?
    @ObservationIgnored var dashboardScrollHandler: ((CGFloat) -> Void)?
    @ObservationIgnored var statusBarActionHandler: ((StatusBarAction) -> Void)?
    @ObservationIgnored var appSwitcherActionHandler: ((UUID) -> Void)?
    @ObservationIgnored var pointerHoverHandler: (() -> Void)?

    init(cursorInactivityDuration: Duration = .seconds(2)) {
        self.cursorInactivityDuration = cursorInactivityDuration
        scheduleCursorHide()
    }

    func register(_ target: any InputTarget, for windowID: UUID) {
        targets[windowID] = WeakInputTarget(target)
    }

    func unregister(windowID: UUID) {
        targets.removeValue(forKey: windowID)
        windowLayouts.removeValue(forKey: windowID)
        pressedRegions.removeValue(forKey: windowID)
    }

    func updateWindowLayout(_ layout: WindowChromeLayout, for windowID: UUID) {
        windowLayouts[windowID] = layout
    }

    func removeWindowLayout(for windowID: UUID) {
        windowLayouts.removeValue(forKey: windowID)
        pressedRegions.removeValue(forKey: windowID)
    }

    func chromeRegion(in windowID: UUID?) -> WindowChromeRegion {
        guard let windowID, let layout = windowLayouts[windowID] else { return .surface }
        return layout.region(at: cursor)
    }

    func updateDashboardHitFrames(_ frames: [UUID: CGRect], in canvasSize: CGSize) {
        let width = max(canvasSize.width, 1)
        let height = max(canvasSize.height, 1)
        dashboardHitFrames = frames.mapValues { frame in
            CGRect(
                x: frame.minX / width,
                y: frame.minY / height,
                width: frame.width / width,
                height: frame.height / height
            )
        }
    }

    func clearDashboardHitFrames() {
        dashboardHitFrames = [:]
        pressedDashboardItemID = nil
    }

    func updateStatusBarHitFrames(_ frames: [StatusBarAction: CGRect], in canvasSize: CGSize) {
        let width = max(canvasSize.width, 1)
        let height = max(canvasSize.height, 1)
        statusBarHitFrames = frames.mapValues { frame in
            CGRect(
                x: frame.minX / width,
                y: frame.minY / height,
                width: frame.width / width,
                height: frame.height / height
            )
        }
    }

    func clearStatusBarHitFrames() {
        statusBarHitFrames = [:]
        pressedStatusBarAction = nil
    }

    func setAppSwitcherPresented(_ isPresented: Bool) {
        isAppSwitcherPresented = isPresented
        guard !isPresented else { return }
        appSwitcherHitFrames = [:]
        pressedAppSwitcherWindowID = nil
    }

    func updateAppSwitcherHitFrames(_ frames: [UUID: CGRect], in canvasSize: CGSize) {
        let width = max(canvasSize.width, 1)
        let height = max(canvasSize.height, 1)
        appSwitcherHitFrames = frames.mapValues { frame in
            CGRect(
                x: frame.minX / width,
                y: frame.minY / height,
                width: frame.width / width,
                height: frame.height / height
            )
        }
    }

    func clearAppSwitcherHitFrames() {
        setAppSwitcherPresented(false)
    }

    func statusBarAction(at normalizedPosition: CGPoint? = nil) -> StatusBarAction? {
        let point = normalizedPosition ?? cursor
        return statusBarHitFrames.first(where: { $0.value.contains(point) })?.key
    }

    func dashboardItem(at normalizedPosition: CGPoint? = nil) -> UUID? {
        let point = normalizedPosition ?? cursor
        return dashboardHitFrames.first(where: { $0.value.contains(point) })?.key
    }

    func appSwitcherItem(at normalizedPosition: CGPoint? = nil) -> UUID? {
        let point = normalizedPosition ?? cursor
        return appSwitcherHitFrames.first(where: { $0.value.contains(point) })?.key
    }

    func isHoveringInteractiveTarget(in windowID: UUID?) -> Bool {
        interactiveTarget(in: windowID) != nil
    }

    func movePointer(delta: CGVector, in windowID: UUID?) {
        let newPosition = CGPoint(
            x: (cursor.x + delta.dx).clamped(to: 0 ... 1),
            y: (cursor.y + delta.dy).clamped(to: 0 ... 1)
        )
        let didMove = newPosition != cursor
        cursor = newPosition
        if didMove {
            pointerDidMove(in: windowID)
        }
        guard !isAppSwitcherPresented else { return }
        dispatchPointerMove(to: windowID)
    }

    func movePointer(to normalizedPosition: CGPoint, in windowID: UUID?) {
        let newPosition = CGPoint(
            x: normalizedPosition.x.clamped(to: 0 ... 1),
            y: normalizedPosition.y.clamped(to: 0 ... 1)
        )
        let didMove = newPosition != cursor
        cursor = newPosition
        if didMove {
            pointerDidMove(in: windowID)
        }
        guard !isAppSwitcherPresented else { return }
        dispatchPointerMove(to: windowID)
    }

    func pointerDown(in windowID: UUID?) {
        if isAppSwitcherPresented {
            pressedAppSwitcherWindowID = appSwitcherItem()
            return
        }
        if let action = statusBarAction() {
            pressedStatusBarAction = action
            return
        }
        guard let windowID else {
            pressedDashboardItemID = dashboardItem()
            return
        }
        let region = chromeRegion(in: windowID)
        pressedRegions[windowID] = region

        guard region == .surface else { return }
        dispatch(
            .pointerDown(normalizedPosition: surfacePosition(in: windowID, clamped: true)),
            to: windowID
        )
    }

    func pointerUp(in windowID: UUID?) {
        if isAppSwitcherPresented {
            let pressedWindowID = pressedAppSwitcherWindowID
            pressedAppSwitcherWindowID = nil
            if let pressedWindowID, appSwitcherItem() == pressedWindowID {
                appSwitcherActionHandler?(pressedWindowID)
            }
            return
        }
        if let pressedStatusBarAction {
            self.pressedStatusBarAction = nil
            if statusBarAction() == pressedStatusBarAction {
                statusBarActionHandler?(pressedStatusBarAction)
            }
            return
        }
        guard let windowID else {
            let pressedItemID = pressedDashboardItemID
            pressedDashboardItemID = nil
            if let pressedItemID, dashboardItem() == pressedItemID {
                dashboardActionHandler?(pressedItemID)
            }
            return
        }
        let pressedRegion = pressedRegions.removeValue(forKey: windowID)

        switch pressedRegion {
        case .surface:
            dispatch(
                .pointerUp(normalizedPosition: surfacePosition(in: windowID, clamped: true)),
                to: windowID
            )
        case .closeButton where chromeRegion(in: windowID) == .closeButton:
            chromeActionHandler?(windowID, .close)
        case .minimizeButton where chromeRegion(in: windowID) == .minimizeButton:
            chromeActionHandler?(windowID, .minimize)
        case .moveFartherButton where chromeRegion(in: windowID) == .moveFartherButton:
            chromeActionHandler?(windowID, .moveFarther)
        case .moveCloserButton where chromeRegion(in: windowID) == .moveCloserButton:
            chromeActionHandler?(windowID, .moveCloser)
        default:
            break
        }
    }

    func scroll(delta: CGVector, in windowID: UUID?) {
        guard !isAppSwitcherPresented else { return }
        guard windowID != nil else {
            dashboardScrollHandler?(delta.dy)
            return
        }
        dispatch(.scroll(normalizedDelta: delta), to: windowID)
    }

    func insertText(_ text: String, in windowID: UUID?) {
        guard !isAppSwitcherPresented, !text.isEmpty else { return }
        dispatch(.insertText(text), to: windowID)
    }

    func back(in windowID: UUID?) {
        guard !isAppSwitcherPresented else { return }
        dispatch(.back, to: windowID)
    }

    func media(_ command: MediaCommand, in windowID: UUID?) {
        guard !isAppSwitcherPresented else { return }
        dispatch(.media(command), to: windowID)
    }

    func resetCursor() {
        cursor = CGPoint(x: 0.5, y: 0.5)
        hoveredTarget = nil
        revealCursor()
    }

    private func pointerDidMove(in windowID: UUID?) {
        revealCursor()

        let target = interactiveTarget(in: windowID)
        guard target != hoveredTarget else { return }
        hoveredTarget = target
        if target != nil {
            pointerHoverHandler?()
        }
    }

    private func interactiveTarget(in windowID: UUID?) -> PointerHoverTarget? {
        if isAppSwitcherPresented {
            return appSwitcherItem().map(PointerHoverTarget.appSwitcher)
        }
        if let action = statusBarAction() {
            return .statusBar(action)
        }
        if windowID == nil, let itemID = dashboardItem() {
            return .dashboard(itemID)
        }
        guard let windowID else { return nil }
        let region = chromeRegion(in: windowID)
        switch region {
        case .closeButton, .minimizeButton, .moveFartherButton, .moveCloserButton, .moveHandle:
            return .windowChrome(windowID, region)
        case .outside, .surface, .titleBar:
            return nil
        }
    }

    private func revealCursor() {
        isCursorVisible = true
        scheduleCursorHide()
    }

    private func scheduleCursorHide() {
        cursorInactivityTask?.cancel()
        cursorInactivityTask = Task { @MainActor [weak self, duration = cursorInactivityDuration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.isCursorVisible = false
        }
    }

    private func dispatchPointerMove(to windowID: UUID?) {
        guard let windowID,
              chromeRegion(in: windowID) == .surface else { return }
        dispatch(.pointerMoved(normalizedPosition: surfacePosition(in: windowID)), to: windowID)
    }

    private func surfacePosition(in windowID: UUID, clamped: Bool = false) -> CGPoint {
        windowLayouts[windowID]?.surfacePosition(for: cursor, clamped: clamped) ?? cursor
    }

    private func dispatch(_ command: InputCommand, to windowID: UUID?) {
        guard let windowID else { return }
        if let target = targets[windowID]?.value {
            target.handle(command)
        } else {
            targets.removeValue(forKey: windowID)
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func rotated(around center: CGPoint, by radians: Double) -> CGPoint {
        let translatedX = x - center.x
        let translatedY = y - center.y
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGPoint(
            x: center.x + translatedX * cosine - translatedY * sine,
            y: center.y + translatedX * sine + translatedY * cosine
        )
    }
}
