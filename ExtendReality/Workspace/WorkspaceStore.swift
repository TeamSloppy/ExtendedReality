import CoreGraphics
import Foundation
import Observation

enum WorkspacePresentationMode: Equatable, Sendable {
    case widgets
    case windows
}

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var windows: [WorkspaceWindow]
    private(set) var layoutMode: WorkspaceLayoutMode
    private(set) var stackOrder: [UUID]
    private(set) var stackTransform: WorkspaceStackTransform
    private(set) var presentationMode: WorkspacePresentationMode
    private(set) var isDashboardPresented = true
    var activeWindowID: UUID?
    var controlMode: ControlMode = .pointer
    var isExternalDisplayConnected = false
    var isAppSwitcherPresented = false
    private(set) var expandedWindowIDs: Set<UUID> = []
    private(set) var activePanelIDs: [UUID: SpatialPanelID] = [:]

    @ObservationIgnored private let persistence: WorkspacePersistence
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var transformsBeforeExpansion: [UUID: SpatialAppTransform3DoF] = [:]
    @ObservationIgnored private var stackDragYaw = 0.0
    @ObservationIgnored private var smoothFollowSmoothers: [UUID: HeadPoseSmoother] = [:]
    private var runtimeLayouts: [UUID: SpatialAppLayout] = [:]

    private static let smoothFollowResponseTime: TimeInterval = 0.35

    init(persistence: WorkspacePersistence) {
        self.persistence = persistence
        let restored = persistence.load()
        let restoredWindows = restored.windows.isEmpty ? Self.defaultWindows : restored.windows
        windows = restoredWindows
        layoutMode = restored.layoutMode
        stackOrder = WorkspaceLayoutProjection.normalizedOrder(
            restored.stackOrder,
            windows: restoredWindows
        )
        stackTransform = restored.stackTransform
        presentationMode = .widgets
        stackTransform.clamp()
        for index in windows.indices {
            windows[index].isMinimized = true
        }
        activeWindowID = nil
    }

    var activeWindow: WorkspaceWindow? {
        windows.first(where: { $0.id == activeWindowID })
    }

    var activePanelID: SpatialPanelID? {
        guard let activeWindowID else { return nil }
        return activePanelIDs[activeWindowID] ?? layout(for: activeWindowID)?.primaryPanelID
    }

    @discardableResult
    func addWindow(kind: WindowKind) -> WorkspaceWindow {
        addWindow(title: kind.title, source: .initial(for: kind))
    }

    @discardableResult
    func addWindow(
        title: String,
        source: WindowSource,
        transform: WindowTransform3DoF = .centered,
        contentAspectRatio: Double? = nil
    ) -> WorkspaceWindow {
        let nextZ = (windows.map(\.zIndex).max() ?? -1) + 1
        let horizontalOffset = Double((windows.count % 3) - 1) * 8
        var transform = transform
        transform.yaw = horizontalOffset
        let window = WorkspaceWindow(
            title: title,
            source: source,
            transform: transform,
            zIndex: nextZ,
            contentAspectRatio: contentAspectRatio
        )
        windows.append(window)
        stackOrder.append(window.id)
        activeWindowID = window.id
        presentationMode = .windows
        isDashboardPresented = false
        activePanelIDs[window.id] = layout(for: window).primaryPanelID
        isAppSwitcherPresented = false
        scheduleSave()
        return window
    }

    func focus(_ id: UUID) {
        activateWindow(id, centeredFor: nil)
    }

    func focusAndCenter(_ id: UUID, for headPose: HeadPose = .identity) {
        activateWindow(id, centeredFor: headPose)
    }

    func focusAdjacentWindow(by offset: Int) {
        guard offset != 0 else { return }
        let visibleIDs = stackOrder.filter { id in
            windows.first(where: { $0.id == id })?.isMinimized == false
        }
        guard visibleIDs.count > 1 else { return }
        let currentIndex = activeWindowID.flatMap { visibleIDs.firstIndex(of: $0) } ?? 0
        let count = visibleIDs.count
        let nextIndex = ((currentIndex + offset) % count + count) % count
        focus(visibleIDs[nextIndex])
    }

    private func activateWindow(_ id: UUID, centeredFor headPose: HeadPose?) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let nextZ = (windows.map(\.zIndex).max() ?? 0) + 1
        windows[index].zIndex = nextZ
        windows[index].isMinimized = false
        activeWindowID = id
        presentationMode = .windows
        isDashboardPresented = false
        if let headPose {
            centerWindowOrStack(id, for: headPose)
        }
        activePanelIDs[id] = activePanelIDs[id] ?? layout(for: windows[index]).primaryPanelID
        isAppSwitcherPresented = false
        scheduleSave()
    }

    func close(_ id: UUID) {
        windows.removeAll(where: { $0.id == id })
        stackOrder.removeAll(where: { $0 == id })
        runtimeLayouts.removeValue(forKey: id)
        activePanelIDs.removeValue(forKey: id)
        expandedWindowIDs.remove(id)
        transformsBeforeExpansion.removeValue(forKey: id)
        if activeWindowID == id {
            activeWindowID = windows.max(by: { $0.zIndex < $1.zIndex })?.id
            controlMode = .pointer
        }
        if windows.isEmpty {
            isAppSwitcherPresented = false
        }
        if !windows.contains(where: { !$0.isMinimized }) {
            presentationMode = .widgets
        }
        scheduleSave()
    }

    func toggleMinimize(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        restoreExpandedTransformIfNeeded(for: id, at: index)
        windows[index].isMinimized.toggle()
        if windows[index].isMinimized, activeWindowID == id {
            activeWindowID = windows
                .filter { !$0.isMinimized }
                .max(by: { $0.zIndex < $1.zIndex })?.id
            controlMode = .pointer
        }
        if !windows.contains(where: { !$0.isMinimized }) {
            presentationMode = .widgets
        } else if !windows[index].isMinimized {
            presentationMode = .windows
        }
        scheduleSave()
    }

    func toggleLayoutOrientation(_ id: UUID) {
        mutateWindow(id) { window in
            window.layoutOrientation = window.effectiveLayoutOrientation.toggled
        }
    }

    func toggleExpanded(_ id: UUID, for headPose: HeadPose) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }

        if expandedWindowIDs.contains(id) {
            restoreExpandedTransformIfNeeded(for: id, at: index)
        } else {
            transformsBeforeExpansion[id] = windows[index].appTransform
            expandedWindowIDs.insert(id)
            if layoutMode == .stack {
                windows[index].appTransform.scale = 1.3
            } else {
                windows[index].appTransform = SpatialAppTransform3DoF(
                    yaw: windows[index].attachmentMode.isHeadRelative ? 0 : -headPose.yaw,
                    pitch: windows[index].attachmentMode.isHeadRelative ? 0 : headPose.pitch,
                    virtualDistance: 0.78,
                    scale: 1.3
                )
            }
            windows[index].appTransform.clamp()
        }

        activeWindowID = id
        windows[index].isMinimized = false
        presentationMode = .windows
        isDashboardPresented = false
        controlMode = .pointer
        scheduleSave()
    }

    func isExpanded(_ id: UUID) -> Bool {
        expandedWindowIDs.contains(id)
    }

    func beginActiveWindowMove() {
        stackDragYaw = 0
    }

    @discardableResult
    func moveActiveWindow(normalizedDelta: CGVector) -> Int {
        guard let activeWindowID else { return 0 }
        guard layoutMode == .stack else {
            moveWindow(activeWindowID, normalizedDelta: normalizedDelta)
            return 0
        }

        stackTransform.pitch -= Double(normalizedDelta.dy) * 22
        stackTransform.clamp()
        stackDragYaw += Double(normalizedDelta.dx) * (42 / 0.52)
        let reordered = consumeStackReorder(for: activeWindowID)
        scheduleSave()
        return reordered
    }

    func endActiveWindowMove() {
        stackDragYaw = 0
    }

    func moveWindow(_ id: UUID, normalizedDelta: CGVector) {
        mutateWindow(id) { window in
            window.appTransform.yaw += Double(normalizedDelta.dx) * 32
            window.appTransform.pitch -= Double(normalizedDelta.dy) * 22
            window.appTransform.clamp()
        }
    }

    func scaleActiveWindow(by magnificationDelta: CGFloat) {
        guard magnificationDelta.isFinite, magnificationDelta > 0 else { return }
        mutateActiveWindow { window in
            let factor = Double(magnificationDelta)
            window.appTransform.scale *= factor
            window.appTransform.clamp()
        }
    }

    func resizeWindow(_ id: UUID, normalizedDelta: CGFloat) {
        guard normalizedDelta.isFinite else { return }
        let factor = exp(Double(normalizedDelta) * 2.2)
        guard factor.isFinite, factor > 0 else { return }
        mutateWindow(id) { window in
            window.appTransform.scale *= factor
            window.appTransform.clamp()
        }
    }

    func zoomActiveWindow(by magnificationDelta: CGFloat) {
        guard magnificationDelta.isFinite, magnificationDelta > 0 else { return }
        if layoutMode == .stack {
            stackTransform.virtualDistance /= Double(magnificationDelta)
            stackTransform.clamp()
            scheduleSave()
            return
        }
        mutateActiveWindow { window in
            window.appTransform.virtualDistance /= Double(magnificationDelta)
            window.appTransform.clamp()
        }
    }

    func adjustWindowDistance(_ id: UUID, by delta: Double) {
        guard delta.isFinite else { return }
        if layoutMode == .stack {
            stackTransform.virtualDistance += delta
            stackTransform.clamp()
            scheduleSave()
            return
        }
        mutateWindow(id) { window in
            window.appTransform.virtualDistance += delta
            window.appTransform.clamp()
        }
    }

    func setWindowDistance(_ id: UUID, to distance: Double) {
        guard distance.isFinite else { return }
        if layoutMode == .stack {
            stackTransform.virtualDistance = distance
            stackTransform.clamp()
            scheduleSave()
            return
        }
        mutateWindow(id) { window in
            window.appTransform.virtualDistance = distance
            window.appTransform.clamp()
        }
    }

    func recenter() {
        if layoutMode == .stack {
            stackTransform.centerYaw = 0
            stackTransform.pitch = 0
            scheduleSave()
            return
        }
        centerActiveWindow(for: .identity)
    }

    func centerActiveWindow(for headPose: HeadPose) {
        guard let activeWindowID else { return }
        centerWindowOrStack(activeWindowID, for: headPose)
        scheduleSave()
    }

    func showDashboard() {
        guard !isDashboardPresented else { return }
        isDashboardPresented = true
        controlMode = .pointer
        isAppSwitcherPresented = false
    }

    func toggleDashboard() {
        if isDashboardPresented {
            _ = dismissDashboard()
        } else {
            showDashboard()
        }
    }

    @discardableResult
    func dismissDashboard() -> Bool {
        isDashboardPresented = false
        return true
    }

    func showWidgets() {
        presentationMode = .widgets
        isDashboardPresented = false
        isAppSwitcherPresented = false
        controlMode = .pointer
    }

    func showWindows() {
        presentationMode = .windows
        isDashboardPresented = false
        isAppSwitcherPresented = false
        controlMode = .pointer
    }

    @discardableResult
    func restoreMostRecentWindow() -> Bool {
        if let activeWindowID,
           windows.first(where: { $0.id == activeWindowID })?.isMinimized == false {
            isAppSwitcherPresented = false
            presentationMode = .windows
            return true
        }
        guard let windowID = windows.max(by: { $0.zIndex < $1.zIndex })?.id else {
            return false
        }
        focus(windowID)
        presentationMode = .windows
        return true
    }

    func toggleAppSwitcher() {
        guard !windows.isEmpty else {
            isAppSwitcherPresented = false
            return
        }
        isDashboardPresented = false
        presentationMode = .windows
        isAppSwitcherPresented.toggle()
    }

    func dismissAppSwitcher() {
        isAppSwitcherPresented = false
    }

    func setLayoutMode(_ mode: WorkspaceLayoutMode, for headPose: HeadPose) {
        guard layoutMode != mode else { return }
        layoutMode = mode
        stackDragYaw = 0
        smoothFollowSmoothers.removeAll()
        if mode == .stack {
            stackTransform.centerYaw = -headPose.yaw
            stackTransform.pitch = headPose.pitch
            stackTransform.virtualDistance = activeWindow?.appTransform.virtualDistance ?? 1
            stackTransform.clamp()
        }
        scheduleSave()
    }

    func toggleLayoutMode(for headPose: HeadPose) {
        setLayoutMode(layoutMode == .freeSpace ? .stack : .freeSpace, for: headPose)
    }

    func setAttachmentMode(
        _ mode: WindowAttachmentMode,
        for windowID: UUID,
        headPose: HeadPose
    ) {
        guard layoutMode == .freeSpace,
              let index = windows.firstIndex(where: { $0.id == windowID }),
              windows[index].attachmentMode != mode else { return }

        let previousProjectionPose = projectionHeadPose(
            for: windows[index].attachmentMode,
            windowID: windowID,
            headPose: headPose
        )
        let nextProjectionPose: HeadPose
        switch mode {
        case .anchor:
            smoothFollowSmoothers.removeValue(forKey: windowID)
            nextProjectionPose = headPose
        case .smoothFollow:
            nextProjectionPose = resetSmoothFollow(for: windowID, at: headPose)
        case .follow:
            smoothFollowSmoothers.removeValue(forKey: windowID)
            nextProjectionPose = .identity
        }
        windows[index].appTransform.yaw += previousProjectionPose.yaw - nextProjectionPose.yaw
        windows[index].appTransform.pitch += nextProjectionPose.pitch - previousProjectionPose.pitch
        windows[index].appTransform.clamp()
        windows[index].attachmentMode = mode
        scheduleSave()
    }

    func toggleAttachmentMode(for windowID: UUID, headPose: HeadPose) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        setAttachmentMode(
            window.attachmentMode.next,
            for: windowID,
            headPose: headPose
        )
    }

    func updateSource(for id: UUID, _ source: WindowSource) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].source = source
        scheduleSave()
    }

    func layout(for windowID: UUID) -> SpatialAppLayout? {
        guard let window = windows.first(where: { $0.id == windowID }) else { return nil }
        return layout(for: window)
    }

    func layout(for window: WorkspaceWindow) -> SpatialAppLayout {
        runtimeLayouts[window.id] ?? SpatialAppLayout.defaultLayout(for: window)
    }

    func presentations(
        for visibleWindows: [WorkspaceWindow],
        headPose: HeadPose
    ) -> [UUID: WorkspaceWindowPresentation] {
        let smoothWindowIDs = Set(
            visibleWindows.lazy
                .filter { $0.attachmentMode == .smoothFollow }
                .map(\.id)
        )
        smoothFollowSmoothers = smoothFollowSmoothers.filter {
            smoothWindowIDs.contains($0.key)
        }
        let smoothFollowHeadPoses = Dictionary(
            uniqueKeysWithValues: smoothWindowIDs.map { windowID in
                (
                    windowID,
                    smoothFollowProjectionPose(for: windowID, headPose: headPose)
                )
            }
        )
        return WorkspaceLayoutProjection.presentations(
            windows: visibleWindows,
            layouts: Dictionary(
                uniqueKeysWithValues: visibleWindows.map { ($0.id, layout(for: $0)) }
            ),
            layoutMode: layoutMode,
            stackOrder: stackOrder,
            stackTransform: stackTransform,
            headPose: headPose,
            smoothFollowHeadPoses: smoothFollowHeadPoses
        )
    }

    func stackPosition(for windowID: UUID) -> (index: Int, count: Int)? {
        guard layoutMode == .stack else { return nil }
        let visibleIDs = WorkspaceLayoutProjection.normalizedOrder(
            stackOrder,
            windows: windows.filter { !$0.isMinimized }
        )
        guard let index = visibleIDs.firstIndex(of: windowID) else { return nil }
        return (index, visibleIDs.count)
    }

    func setLayout(_ layout: SpatialAppLayout, for windowID: UUID) throws {
        guard windows.contains(where: { $0.id == windowID }) else {
            throw SpatialWindowError.missingWindow
        }
        let validated = try layout.validated(permitsPrevalidatedWebContent: true)
        runtimeLayouts[windowID] = validated
        if !validated.panels.contains(where: { $0.id == activePanelIDs[windowID] }) {
            activePanelIDs[windowID] = validated.primaryPanelID
        }
    }

    func resetLayout(for windowID: UUID) {
        runtimeLayouts.removeValue(forKey: windowID)
        if let layout = layout(for: windowID) {
            activePanelIDs[windowID] = layout.primaryPanelID
        }
    }

    func focusPanel(_ panelID: SpatialPanelID, in windowID: UUID) {
        guard layout(for: windowID)?.panels.contains(where: { $0.id == panelID }) == true else { return }
        focus(windowID)
        activePanelIDs[windowID] = panelID
    }

    func resetWorkspace() {
        windows = Self.defaultWindows
        layoutMode = .freeSpace
        stackOrder = windows.map(\.id)
        stackTransform = .centered
        activeWindowID = windows.last?.id
        presentationMode = windows.contains(where: { !$0.isMinimized }) ? .windows : .widgets
        isDashboardPresented = false
        expandedWindowIDs = []
        transformsBeforeExpansion = [:]
        smoothFollowSmoothers = [:]
        runtimeLayouts = [:]
        activePanelIDs = [:]
        controlMode = .pointer
        isAppSwitcherPresented = false
        scheduleSave()
    }

    private func mutateActiveWindow(_ mutation: (inout WorkspaceWindow) -> Void) {
        guard let activeWindowID else { return }
        mutateWindow(activeWindowID, mutation)
    }

    private func mutateWindow(_ id: UUID, _ mutation: (inout WorkspaceWindow) -> Void) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        mutation(&windows[index])
        scheduleSave()
    }

    private func center(_ window: inout WorkspaceWindow, for headPose: HeadPose) {
        if window.attachmentMode.isHeadRelative {
            window.appTransform.yaw = 0
            window.appTransform.pitch = 0
            if window.attachmentMode == .smoothFollow {
                _ = resetSmoothFollow(for: window.id, at: headPose)
            }
        } else {
            window.appTransform.yaw = -headPose.yaw
            window.appTransform.pitch = headPose.pitch
        }
        window.appTransform.clamp()
    }

    private func projectionHeadPose(
        for mode: WindowAttachmentMode,
        windowID: UUID,
        headPose: HeadPose
    ) -> HeadPose {
        switch mode {
        case .anchor:
            headPose
        case .smoothFollow:
            smoothFollowProjectionPose(for: windowID, headPose: headPose)
        case .follow:
            .identity
        }
    }

    private func resetSmoothFollow(for windowID: UUID, at headPose: HeadPose) -> HeadPose {
        var smoother = HeadPoseSmoother(responseTime: Self.smoothFollowResponseTime)
        _ = smoother.filter(headPose)
        smoothFollowSmoothers[windowID] = smoother
        return .identity
    }

    private func smoothFollowProjectionPose(for windowID: UUID, headPose: HeadPose) -> HeadPose {
        var smoother = smoothFollowSmoothers[windowID]
            ?? HeadPoseSmoother(responseTime: Self.smoothFollowResponseTime)
        let filteredPose = smoother.filter(headPose)
        smoothFollowSmoothers[windowID] = smoother
        return headPose.offset(relativeTo: filteredPose)
    }

    private func centerWindowOrStack(_ windowID: UUID, for headPose: HeadPose) {
        guard layoutMode == .stack else {
            guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
            center(&windows[index], for: headPose)
            return
        }

        let visibleWindows = windows.filter { !$0.isMinimized }
        let presentations = presentations(for: visibleWindows, headPose: headPose)
        guard let currentYaw = presentations[windowID]?.window.appTransform.yaw else { return }
        stackTransform.centerYaw += -headPose.yaw - currentYaw
        stackTransform.pitch = headPose.pitch
        stackTransform.clamp()
    }

    private func consumeStackReorder(for windowID: UUID) -> Int {
        var reorderCount = 0
        while true {
            let visibleWindows = windows.filter { !$0.isMinimized }
            let visibleOrder = WorkspaceLayoutProjection.normalizedOrder(
                stackOrder,
                windows: visibleWindows
            )
            guard let visibleIndex = visibleOrder.firstIndex(of: windowID) else { break }
            let direction = stackDragYaw > 0 ? 1 : -1
            guard stackDragYaw != 0 else { break }
            let neighborIndex = visibleIndex + direction
            guard visibleOrder.indices.contains(neighborIndex) else {
                stackDragYaw = 0
                break
            }

            let presentations = presentations(for: visibleWindows, headPose: .identity)
            guard let currentYaw = presentations[windowID]?.window.appTransform.yaw,
                  let neighborYaw = presentations[visibleOrder[neighborIndex]]?.window.appTransform.yaw else {
                break
            }
            let threshold = max(abs(neighborYaw - currentYaw) / 2, 4)
            guard abs(stackDragYaw) >= threshold else { break }

            guard let source = stackOrder.firstIndex(of: windowID),
                  let destination = stackOrder.firstIndex(of: visibleOrder[neighborIndex]) else { break }
            stackOrder.swapAt(source, destination)
            stackDragYaw -= Double(direction) * threshold
            reorderCount += 1
        }
        return reorderCount
    }

    private func restoreExpandedTransformIfNeeded(for id: UUID, at index: Int) {
        guard expandedWindowIDs.remove(id) != nil else { return }
        if let transform = transformsBeforeExpansion.removeValue(forKey: id) {
            windows[index].appTransform = transform
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            persistence.save(
                WorkspacePersistenceState(
                    windows: windows,
                    layoutMode: layoutMode,
                    stackOrder: stackOrder,
                    stackTransform: stackTransform
                )
            )
        }
    }

    private static var defaultWindows: [WorkspaceWindow] {
        []
    }
}

@MainActor
final class SpatialWindowClient {
    let windowID: UUID
    private unowned let workspace: WorkspaceStore
    private let allowedOrigins: Set<PWAOrigin>?
    private let permissionProvider: () -> Bool
    private let layoutDidChange: (SpatialAppLayout?) -> Void

    init(
        windowID: UUID,
        workspace: WorkspaceStore,
        allowedOrigins: Set<PWAOrigin>? = nil,
        permissionProvider: @escaping () -> Bool = { true },
        layoutDidChange: @escaping (SpatialAppLayout?) -> Void = { _ in }
    ) {
        self.windowID = windowID
        self.workspace = workspace
        self.allowedOrigins = allowedOrigins
        self.permissionProvider = permissionProvider
        self.layoutDidChange = layoutDidChange
    }

    var layout: SpatialAppLayout? {
        workspace.layout(for: windowID)
    }

    func setLayout(_ layout: SpatialAppLayout) throws {
        guard permissionProvider() else { throw SpatialWindowError.permissionDenied }
        let validated = try layout.validated(allowedOrigins: allowedOrigins)
        try workspace.setLayout(validated, for: windowID)
        layoutDidChange(validated)
    }

    func createPanel(_ panel: SpatialPanelDescriptor) throws {
        guard var layout else { throw SpatialWindowError.missingWindow }
        guard !layout.panels.contains(where: { $0.id == panel.id }) else {
            throw SpatialWindowError.invalidPanelIdentifier
        }
        layout.panels.append(panel)
        try setLayout(layout)
    }

    func updatePanel(_ panel: SpatialPanelDescriptor) throws {
        guard var layout,
              let index = layout.panels.firstIndex(where: { $0.id == panel.id }) else {
            throw SpatialWindowError.invalidPanelIdentifier
        }
        layout.panels[index] = panel
        try setLayout(layout)
    }

    func removePanel(_ panelID: SpatialPanelID) throws {
        guard var layout, panelID != layout.primaryPanelID else {
            throw SpatialWindowError.invalidPanelIdentifier
        }
        layout.panels.removeAll(where: { $0.id == panelID })
        try setLayout(layout)
    }

    func resetLayout() {
        workspace.resetLayout(for: windowID)
        layoutDidChange(nil)
    }
}

extension SpatialAppLayout {
    static func defaultLayout(for window: WorkspaceWindow) -> Self {
        if case .youtube = window.source {
            return .youtubeCompact
        }
        return SpatialAppLayout(panels: [
            SpatialPanelDescriptor(
                id: .primary,
                accessibilityLabel: window.title,
                placement: SpatialPanelPlacement(
                    width: window.kind == .remoteDesktop ? 0.90 : 0.72,
                    height: window.kind == .remoteDesktop ? 0.80 : 0.68
                ),
                content: .primary
            )
        ])
    }

    static let youtubeCompact = SpatialAppLayout(panels: [
        SpatialPanelDescriptor(
            id: .primary,
            accessibilityLabel: "Spatial Video",
            placement: SpatialPanelPlacement(width: 0.78, height: 0.46),
            content: .primary
        )
    ])

    static let youtube = SpatialAppLayout(primaryPanelID: "video", panels: [
        SpatialPanelDescriptor(
            id: "video",
            accessibilityLabel: "YouTube video",
            placement: SpatialPanelPlacement(width: 0.72, height: 0.405),
            content: .native("youtube.video")
        ),
        SpatialPanelDescriptor(
            id: "info",
            accessibilityLabel: "Video information",
            placement: SpatialPanelPlacement(yaw: -26, pitch: 1, depth: 0.08, width: 0.24, height: 0.34, layer: 1),
            content: .native("youtube.info")
        ),
        SpatialPanelDescriptor(
            id: "search",
            accessibilityLabel: "YouTube search",
            placement: SpatialPanelPlacement(yaw: 26, pitch: 1, depth: 0.08, width: 0.28, height: 0.38, layer: 1),
            content: .native("youtube.search")
        ),
        SpatialPanelDescriptor(
            id: "transport",
            accessibilityLabel: "Playback controls",
            placement: SpatialPanelPlacement(yaw: 0, pitch: -17, depth: -0.04, width: 0.52, height: 0.11, layer: 2),
            content: .native("youtube.transport")
        ),
    ])
}
