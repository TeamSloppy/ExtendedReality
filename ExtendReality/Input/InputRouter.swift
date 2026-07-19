import CoreGraphics
import Foundation
import Observation

enum WindowChromeRegion: Equatable {
    case outside
    case surface
    case orientationButton
    case minimizeButton
    case expandButton
    case closeButton
    case moveHandle
    case resizeHandle
}

enum WindowChromeAction: Equatable {
    case toggleOrientation
    case minimize
    case toggleExpanded
    case close
}

struct WindowChromeLayout: Equatable {
    static let controlBarHeight: CGFloat = 56
    static let controlBarGap: CGFloat = 20
    static let handleGap: CGFloat = 14
    static let handleHeight: CGFloat = 28
    static let resizeHandleWidth: CGFloat = 32
    static let resizeHandleHeight: CGFloat = 128
    static var verticalChromeHeight: CGFloat {
        controlBarHeight + controlBarGap + handleGap + handleHeight
    }

    let frame: CGRect
    let canvasSize: CGSize
    let rotationRadians: Double
    let showsOrientation: Bool

    init(size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        canvasSize = size
        rotationRadians = 0
        showsOrientation = true
    }

    init(
        frame: CGRect,
        in canvasSize: CGSize,
        rotationRadians: Double = 0,
        showsOrientation: Bool = true
    ) {
        self.frame = frame
        self.canvasSize = canvasSize
        self.rotationRadians = rotationRadians
        self.showsOrientation = showsOrientation
    }

    func region(at normalizedPosition: CGPoint) -> WindowChromeRegion {
        guard let point = localPoint(for: normalizedPosition) else { return .outside }

        if resizeHandleRect.contains(point) {
            return .resizeHandle
        }
        if surfaceRect.contains(point) {
            return .surface
        }
        if controlBarRect.contains(point) {
            let controlCount: CGFloat = showsOrientation ? 4 : 3
            let index = Int((point.x - controlBarRect.minX) / max(controlBarRect.width / controlCount, 1))
            if showsOrientation {
                switch index {
                case 0: return .orientationButton
                case 1: return .minimizeButton
                case 2: return .expandButton
                default: return .closeButton
                }
            } else {
                switch index {
                case 0: return .minimizeButton
                case 1: return .expandButton
                default: return .closeButton
                }
            }
        }
        if moveHandleRect.contains(point) {
            return .moveHandle
        }
        return .outside
    }

    func surfacePosition(for normalizedPosition: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard let point = localPoint(for: normalizedPosition, clamped: clamped) else { return nil }
        guard clamped || surfaceRect.contains(point) else { return nil }

        return CGPoint(
            x: ((point.x - surfaceRect.minX) / max(surfaceRect.width, 1)).clamped(to: 0 ... 1),
            y: ((point.y - surfaceRect.minY) / max(surfaceRect.height, 1)).clamped(to: 0 ... 1)
        )
    }

    func canvasPosition(forSurfacePosition normalizedPosition: CGPoint) -> CGPoint {
        let localPoint = CGPoint(
            x: surfaceRect.minX + normalizedPosition.x.clamped(to: 0 ... 1) * surfaceRect.width,
            y: surfaceRect.minY + normalizedPosition.y.clamped(to: 0 ... 1) * surfaceRect.height
        )
        let unrotatedCanvasPoint = CGPoint(
            x: frame.minX + localPoint.x,
            y: frame.minY + localPoint.y
        )
        let canvasPoint = unrotatedCanvasPoint.rotated(
            around: frame.center,
            by: rotationRadians
        )
        return CGPoint(
            x: (canvasPoint.x / max(canvasSize.width, 1)).clamped(to: 0 ... 1),
            y: (canvasPoint.y / max(canvasSize.height, 1)).clamped(to: 0 ... 1)
        )
    }

    private var surfaceRect: CGRect {
        CGRect(
            x: 0,
            y: Self.controlBarHeight + Self.controlBarGap,
            width: frame.width,
            height: max(frame.height - Self.verticalChromeHeight, 1)
        )
    }

    private var controlBarRect: CGRect {
        let width = min(max(frame.width * 0.84, 240), 680)
        return CGRect(
            x: (frame.width - width) / 2,
            y: 0,
            width: width,
            height: Self.controlBarHeight
        )
    }

    private var moveHandleRect: CGRect {
        let width = min(max(frame.width * 0.18, 104), 180)
        return CGRect(
            x: (frame.width - width) / 2,
            y: frame.height - Self.handleHeight,
            width: width,
            height: Self.handleHeight
        )
    }

    private var resizeHandleRect: CGRect {
        CGRect(
            x: max(0, frame.width - Self.resizeHandleWidth),
            y: surfaceRect.midY - Self.resizeHandleHeight / 2,
            width: min(Self.resizeHandleWidth, frame.width),
            height: min(Self.resizeHandleHeight, surfaceRect.height)
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

struct SpatialPanelSurfaceID: Hashable, Sendable {
    let windowID: UUID
    let panelID: SpatialPanelID
}

struct SpatialPanelInputLayout: Equatable {
    let windowID: UUID
    let panelID: SpatialPanelID
    let frame: CGRect
    let canvasSize: CGSize
    let appZIndex: Int
    let layer: Int
    let depth: Double
    var rotationRadians: Double = 0

    func contains(_ normalizedPosition: CGPoint) -> Bool {
        frame.contains(localCanvasPoint(for: normalizedPosition))
    }

    func localPosition(for normalizedPosition: CGPoint, clamped: Bool = false) -> CGPoint? {
        var point = localCanvasPoint(for: normalizedPosition)
        if clamped {
            point.x = point.x.clamped(to: frame.minX ... frame.maxX)
            point.y = point.y.clamped(to: frame.minY ... frame.maxY)
        } else if !frame.contains(point) {
            return nil
        }
        return CGPoint(
            x: ((point.x - frame.minX) / max(frame.width, 1)).clamped(to: 0 ... 1),
            y: ((point.y - frame.minY) / max(frame.height, 1)).clamped(to: 0 ... 1)
        )
    }

    private func canvasPoint(for normalizedPosition: CGPoint) -> CGPoint {
        CGPoint(
            x: normalizedPosition.x * max(canvasSize.width, 1),
            y: normalizedPosition.y * max(canvasSize.height, 1)
        )
    }

    private func localCanvasPoint(for normalizedPosition: CGPoint) -> CGPoint {
        canvasPoint(for: normalizedPosition).rotated(around: frame.center, by: -rotationRadians)
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
    case dock(UUID)
    case appSwitcher(UUID)
    case windowChrome(UUID, WindowChromeRegion)
    case panel(SpatialPanelSurfaceID)
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
    private struct RegisteredWindowLayout {
        var layout: WindowChromeLayout
        var zIndex: Int
    }

    private(set) var cursor = CGPoint(x: 0.5, y: 0.5)
    private(set) var isCursorVisible = true
    @ObservationIgnored private let cursorInactivityDuration: Duration
    @ObservationIgnored private var cursorInactivityTask: Task<Void, Never>?
    @ObservationIgnored private var hoveredTarget: PointerHoverTarget?
    @ObservationIgnored private var targets: [UUID: WeakInputTarget] = [:]
    @ObservationIgnored private var panelTargets: [SpatialPanelSurfaceID: WeakInputTarget] = [:]
    @ObservationIgnored private var panelLayouts: [SpatialPanelSurfaceID: SpatialPanelInputLayout] = [:]
    @ObservationIgnored private var activePanels: [UUID: SpatialPanelID] = [:]
    @ObservationIgnored private var pressedPanel: SpatialPanelSurfaceID?
    @ObservationIgnored private var windowLayouts: [UUID: RegisteredWindowLayout] = [:]
    @ObservationIgnored private var pressedRegions: [UUID: WindowChromeRegion] = [:]
    @ObservationIgnored private var pressedWindowID: UUID?
    @ObservationIgnored private var dashboardHitFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var pressedDashboardItemID: UUID?
    @ObservationIgnored private var statusBarHitFrames: [StatusBarAction: CGRect] = [:]
    @ObservationIgnored private var pressedStatusBarAction: StatusBarAction?
    @ObservationIgnored private var dockHitFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var pressedDockWindowID: UUID?
    @ObservationIgnored private var appSwitcherHitFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var pressedAppSwitcherWindowID: UUID?
    @ObservationIgnored private var isAppSwitcherPresented = false
    @ObservationIgnored var chromeActionHandler: ((UUID, WindowChromeAction) -> Void)?
    @ObservationIgnored var dashboardActionHandler: ((UUID) -> Void)?
    @ObservationIgnored var dashboardScrollHandler: ((CGFloat) -> Void)?
    @ObservationIgnored var statusBarActionHandler: ((StatusBarAction) -> Void)?
    @ObservationIgnored var dockActionHandler: ((UUID) -> Void)?
    @ObservationIgnored var appSwitcherActionHandler: ((UUID) -> Void)?
    @ObservationIgnored var windowFocusHandler: ((UUID) -> Void)?
    @ObservationIgnored var panelFocusHandler: ((UUID, SpatialPanelID) -> Void)?
    @ObservationIgnored var pointerHoverHandler: (() -> Void)?

    init(cursorInactivityDuration: Duration = .seconds(2)) {
        self.cursorInactivityDuration = cursorInactivityDuration
        scheduleCursorHide()
    }

    func register(_ target: any InputTarget, for windowID: UUID) {
        targets[windowID] = WeakInputTarget(target)
    }

    func register(_ target: any InputTarget, for panelID: SpatialPanelID, in windowID: UUID) {
        panelTargets[SpatialPanelSurfaceID(windowID: windowID, panelID: panelID)] = WeakInputTarget(target)
    }

    func unregister(windowID: UUID) {
        targets.removeValue(forKey: windowID)
        panelTargets = panelTargets.filter { $0.key.windowID != windowID }
        panelLayouts = panelLayouts.filter { $0.key.windowID != windowID }
        activePanels.removeValue(forKey: windowID)
        windowLayouts.removeValue(forKey: windowID)
        pressedRegions.removeValue(forKey: windowID)
        if pressedWindowID == windowID {
            pressedWindowID = nil
        }
    }

    func updateWindowLayout(
        _ layout: WindowChromeLayout,
        for windowID: UUID,
        zIndex: Int = 0
    ) {
        windowLayouts[windowID] = RegisteredWindowLayout(layout: layout, zIndex: zIndex)
    }

    func removeWindowLayout(for windowID: UUID) {
        windowLayouts.removeValue(forKey: windowID)
        pressedRegions.removeValue(forKey: windowID)
        if pressedWindowID == windowID {
            pressedWindowID = nil
        }
    }

    func updatePanelLayouts(_ layouts: [SpatialPanelInputLayout]) {
        guard let windowID = layouts.first?.windowID else { return }
        panelLayouts = panelLayouts.filter { $0.key.windowID != windowID }
        for layout in layouts {
            let id = SpatialPanelSurfaceID(windowID: layout.windowID, panelID: layout.panelID)
            panelLayouts[id] = layout
        }
    }

    func removePanelLayouts(for windowID: UUID) {
        panelLayouts = panelLayouts.filter { $0.key.windowID != windowID }
        if pressedPanel?.windowID == windowID { pressedPanel = nil }
    }

    func panel(at normalizedPosition: CGPoint? = nil, in windowID: UUID? = nil) -> SpatialPanelSurfaceID? {
        let point = normalizedPosition ?? cursor
        return panelLayouts
            .filter { registration in
                (windowID == nil || registration.key.windowID == windowID)
                    && registration.value.contains(point)
            }
            .max { lhs, rhs in
                let left = lhs.value
                let right = rhs.value
                if left.appZIndex != right.appZIndex { return left.appZIndex < right.appZIndex }
                if left.layer != right.layer { return left.layer < right.layer }
                return left.depth > right.depth
            }?
            .key
    }

    func chromeRegion(in windowID: UUID?) -> WindowChromeRegion {
        guard let windowID, let registration = windowLayouts[windowID] else { return .surface }
        return registration.layout.region(at: cursor)
    }

    func window(at normalizedPosition: CGPoint? = nil) -> UUID? {
        let point = normalizedPosition ?? cursor
        return windowLayouts
            .filter { $0.value.layout.region(at: point) != .outside }
            .max { lhs, rhs in lhs.value.zIndex < rhs.value.zIndex }?
            .key
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

    func updateDockHitFrames(_ frames: [UUID: CGRect], in canvasSize: CGSize) {
        let width = max(canvasSize.width, 1)
        let height = max(canvasSize.height, 1)
        dockHitFrames = frames.mapValues { frame in
            CGRect(
                x: frame.minX / width,
                y: frame.minY / height,
                width: frame.width / width,
                height: frame.height / height
            )
        }
    }

    func clearDockHitFrames() {
        dockHitFrames = [:]
        pressedDockWindowID = nil
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

    func dockItem(at normalizedPosition: CGPoint? = nil) -> UUID? {
        let point = normalizedPosition ?? cursor
        return dockHitFrames.first(where: { $0.value.contains(point) })?.key
    }

    func appSwitcherItem(at normalizedPosition: CGPoint? = nil) -> UUID? {
        let point = normalizedPosition ?? cursor
        return appSwitcherHitFrames.first(where: { $0.value.contains(point) })?.key
    }

    func isHoveringInteractiveTarget(in windowID: UUID?) -> Bool {
        interactiveTarget(in: windowID) != nil
    }

    func surfaceCursorPosition(in windowID: UUID) -> CGPoint {
        surfacePosition(in: windowID, clamped: true)
    }

    func movePointer(
        delta: CGVector,
        in windowID: UUID?,
        dispatchesToSurface: Bool = true
    ) {
        let newPosition = CGPoint(
            x: (cursor.x + delta.dx).clamped(to: 0 ... 1),
            y: (cursor.y + delta.dy).clamped(to: 0 ... 1)
        )
        let didMove = newPosition != cursor
        cursor = newPosition
        if didMove {
            pointerDidMove(in: windowID)
        }
        guard !isAppSwitcherPresented, dispatchesToSurface else { return }
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

    func movePointer(toSurfacePosition normalizedPosition: CGPoint, in windowID: UUID) {
        let canvasPosition = windowLayouts[windowID]?.layout.canvasPosition(
            forSurfacePosition: normalizedPosition
        ) ?? normalizedPosition
        movePointer(to: canvasPosition, in: windowID)
    }

    func pointerDown(in windowID: UUID?) {
        if isAppSwitcherPresented {
            pressedAppSwitcherWindowID = appSwitcherItem()
            return
        }
        if let dockWindowID = dockItem() {
            pressedDockWindowID = dockWindowID
            return
        }
        if let action = statusBarAction() {
            pressedStatusBarAction = action
            return
        }
        guard let targetWindowID = window() ?? windowID else {
            pressedDashboardItemID = dashboardItem()
            return
        }
        if targetWindowID != windowID {
            windowFocusHandler?(targetWindowID)
        }

        pressedWindowID = targetWindowID
        let region = chromeRegion(in: targetWindowID)
        pressedRegions[targetWindowID] = region

        guard region == .surface else { return }
        if let panelID = panel(in: targetWindowID) {
            pressedPanel = panelID
            activePanels[targetWindowID] = panelID.panelID
            panelFocusHandler?(targetWindowID, panelID.panelID)
            dispatch(
                .pointerDown(normalizedPosition: panelPosition(for: panelID, clamped: true)),
                to: panelID
            )
            return
        }
        dispatch(
            .pointerDown(normalizedPosition: surfacePosition(in: targetWindowID, clamped: true)),
            to: targetWindowID
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
        if let pressedDockWindowID {
            self.pressedDockWindowID = nil
            if dockItem() == pressedDockWindowID {
                dockActionHandler?(pressedDockWindowID)
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
        if let pressedWindowID {
            self.pressedWindowID = nil
            let pressedRegion = pressedRegions.removeValue(forKey: pressedWindowID)

            switch pressedRegion {
            case .surface:
                if let pressedPanel {
                    self.pressedPanel = nil
                    if panel(in: pressedWindowID) == pressedPanel {
                        dispatch(
                            .pointerUp(normalizedPosition: panelPosition(for: pressedPanel, clamped: true)),
                            to: pressedPanel
                        )
                    }
                } else {
                    dispatch(
                        .pointerUp(normalizedPosition: surfacePosition(in: pressedWindowID, clamped: true)),
                        to: pressedWindowID
                    )
                }
            case .orientationButton where chromeRegion(in: pressedWindowID) == .orientationButton:
                chromeActionHandler?(pressedWindowID, .toggleOrientation)
            case .closeButton where chromeRegion(in: pressedWindowID) == .closeButton:
                chromeActionHandler?(pressedWindowID, .close)
            case .minimizeButton where chromeRegion(in: pressedWindowID) == .minimizeButton:
                chromeActionHandler?(pressedWindowID, .minimize)
            case .expandButton where chromeRegion(in: pressedWindowID) == .expandButton:
                chromeActionHandler?(pressedWindowID, .toggleExpanded)
            default:
                break
            }
            return
        }
        guard windowID == nil else { return }
        let pressedItemID = pressedDashboardItemID
        pressedDashboardItemID = nil
        if let pressedItemID, dashboardItem() == pressedItemID {
            dashboardActionHandler?(pressedItemID)
        }
    }

    func scroll(delta: CGVector, in windowID: UUID?) {
        guard !isAppSwitcherPresented else { return }
        guard windowID != nil else {
            dashboardScrollHandler?(delta.dy)
            return
        }
        dispatchToActivePanelOrWindow(.scroll(normalizedDelta: delta), windowID: windowID)
    }

    func insertText(_ text: String, in windowID: UUID?) {
        guard !isAppSwitcherPresented, !text.isEmpty else { return }
        dispatchToActivePanelOrWindow(.insertText(text), windowID: windowID)
    }

    func back(in windowID: UUID?) {
        guard !isAppSwitcherPresented else { return }
        dispatchToActivePanelOrWindow(.back, windowID: windowID)
    }

    func media(_ command: MediaCommand, in windowID: UUID?) {
        guard !isAppSwitcherPresented else { return }
        dispatchToActivePanelOrWindow(.media(command), windowID: windowID)
    }

    func resetCursor() {
        cursor = CGPoint(x: 0.5, y: 0.5)
        hoveredTarget = nil
        revealCursor()
    }

    func hideCursor() {
        cursorInactivityTask?.cancel()
        isCursorVisible = false
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
        if let windowID = dockItem() {
            return .dock(windowID)
        }
        if let action = statusBarAction() {
            return .statusBar(action)
        }
        if windowID == nil, let itemID = dashboardItem() {
            return .dashboard(itemID)
        }
        guard let windowID else { return nil }
        if let panel = panel(in: windowID) {
            return .panel(panel)
        }
        let region = chromeRegion(in: windowID)
        switch region {
        case .orientationButton, .minimizeButton, .expandButton, .closeButton, .moveHandle, .resizeHandle:
            return .windowChrome(windowID, region)
        case .outside, .surface:
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
        guard let windowID, chromeRegion(in: windowID) == .surface else { return }
        if let panelID = panel(in: windowID) {
            dispatch(
                .pointerMoved(normalizedPosition: panelPosition(for: panelID)),
                to: panelID
            )
            return
        }
        dispatch(.pointerMoved(normalizedPosition: surfacePosition(in: windowID)), to: windowID)
    }

    private func surfacePosition(in windowID: UUID, clamped: Bool = false) -> CGPoint {
        windowLayouts[windowID]?.layout.surfacePosition(for: cursor, clamped: clamped) ?? cursor
    }

    private func dispatch(_ command: InputCommand, to windowID: UUID?) {
        guard let windowID else { return }
        if let target = targets[windowID]?.value {
            target.handle(command)
        } else {
            targets.removeValue(forKey: windowID)
        }
    }

    private func dispatch(_ command: InputCommand, to panelID: SpatialPanelSurfaceID) {
        if let target = panelTargets[panelID]?.value {
            target.handle(command)
        } else if let target = targets[panelID.windowID]?.value {
            target.handle(command)
        } else {
            panelTargets.removeValue(forKey: panelID)
        }
    }

    private func dispatchToActivePanelOrWindow(_ command: InputCommand, windowID: UUID?) {
        guard let windowID else { return }
        if let panelID = activePanels[windowID] {
            dispatch(command, to: SpatialPanelSurfaceID(windowID: windowID, panelID: panelID))
        } else {
            dispatch(command, to: windowID)
        }
    }

    private func panelPosition(for panelID: SpatialPanelSurfaceID, clamped: Bool = false) -> CGPoint {
        panelLayouts[panelID]?.localPosition(for: cursor, clamped: clamped) ?? cursor
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
