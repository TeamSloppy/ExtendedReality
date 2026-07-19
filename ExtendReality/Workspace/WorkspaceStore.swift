import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var windows: [WorkspaceWindow]
    var activeWindowID: UUID?
    var controlMode: ControlMode = .pointer
    var isExternalDisplayConnected = false
    var isAppSwitcherPresented = false
    private(set) var expandedWindowIDs: Set<UUID> = []
    private(set) var activePanelIDs: [UUID: SpatialPanelID] = [:]

    @ObservationIgnored private let persistence: WorkspacePersistence
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var transformsBeforeExpansion: [UUID: SpatialAppTransform3DoF] = [:]
    private var runtimeLayouts: [UUID: SpatialAppLayout] = [:]

    init(persistence: WorkspacePersistence) {
        self.persistence = persistence
        let restored = persistence.load()
        windows = restored.isEmpty ? Self.defaultWindows : restored
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
        activeWindowID = window.id
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

    private func activateWindow(_ id: UUID, centeredFor headPose: HeadPose?) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let nextZ = (windows.map(\.zIndex).max() ?? 0) + 1
        windows[index].zIndex = nextZ
        windows[index].isMinimized = false
        if let headPose {
            center(&windows[index], for: headPose)
        }
        activeWindowID = id
        activePanelIDs[id] = activePanelIDs[id] ?? layout(for: windows[index]).primaryPanelID
        isAppSwitcherPresented = false
        scheduleSave()
    }

    func close(_ id: UUID) {
        windows.removeAll(where: { $0.id == id })
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
            windows[index].appTransform = SpatialAppTransform3DoF(
                yaw: -headPose.yaw,
                pitch: headPose.pitch,
                virtualDistance: 0.78,
                scale: 1.3
            )
            windows[index].appTransform.clamp()
        }

        activeWindowID = id
        windows[index].isMinimized = false
        controlMode = .pointer
        scheduleSave()
    }

    func isExpanded(_ id: UUID) -> Bool {
        expandedWindowIDs.contains(id)
    }

    func moveActiveWindow(normalizedDelta: CGVector) {
        guard let activeWindowID else { return }
        moveWindow(activeWindowID, normalizedDelta: normalizedDelta)
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
        mutateActiveWindow { window in
            window.appTransform.virtualDistance /= Double(magnificationDelta)
            window.appTransform.clamp()
        }
    }

    func adjustWindowDistance(_ id: UUID, by delta: Double) {
        guard delta.isFinite else { return }
        mutateWindow(id) { window in
            window.appTransform.virtualDistance += delta
            window.appTransform.clamp()
        }
    }

    func setWindowDistance(_ id: UUID, to distance: Double) {
        guard distance.isFinite else { return }
        mutateWindow(id) { window in
            window.appTransform.virtualDistance = distance
            window.appTransform.clamp()
        }
    }

    func recenter() {
        centerActiveWindow(for: .identity)
    }

    func centerActiveWindow(for headPose: HeadPose) {
        mutateActiveWindow { window in
            center(&window, for: headPose)
        }
    }

    func showDashboard() {
        for index in windows.indices {
            let id = windows[index].id
            restoreExpandedTransformIfNeeded(for: id, at: index)
            windows[index].isMinimized = true
        }
        activeWindowID = nil
        controlMode = .pointer
        isAppSwitcherPresented = false
        scheduleSave()
    }

    @discardableResult
    func restoreMostRecentWindow() -> Bool {
        if activeWindowID != nil {
            isAppSwitcherPresented = false
            return true
        }
        guard let windowID = windows.max(by: { $0.zIndex < $1.zIndex })?.id else {
            return false
        }
        focus(windowID)
        return true
    }

    func toggleAppSwitcher() {
        guard !windows.isEmpty else {
            isAppSwitcherPresented = false
            return
        }
        isAppSwitcherPresented.toggle()
    }

    func dismissAppSwitcher() {
        isAppSwitcherPresented = false
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
        activeWindowID = windows.last?.id
        expandedWindowIDs = []
        transformsBeforeExpansion = [:]
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
        window.appTransform.yaw = -headPose.yaw
        window.appTransform.pitch = headPose.pitch
        window.appTransform.clamp()
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
            persistence.save(windows)
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
            return .youtube
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
