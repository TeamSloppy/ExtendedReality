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

    @ObservationIgnored private let persistence: WorkspacePersistence
    @ObservationIgnored private var saveTask: Task<Void, Never>?

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

    @discardableResult
    func addWindow(kind: WindowKind) -> WorkspaceWindow {
        addWindow(title: kind.title, source: .initial(for: kind))
    }

    @discardableResult
    func addWindow(title: String, source: WindowSource) -> WorkspaceWindow {
        let nextZ = (windows.map(\.zIndex).max() ?? -1) + 1
        let horizontalOffset = Double((windows.count % 3) - 1) * 8
        var transform = WindowTransform3DoF.centered
        transform.yaw = horizontalOffset
        let window = WorkspaceWindow(
            title: title,
            source: source,
            transform: transform,
            zIndex: nextZ
        )
        windows.append(window)
        activeWindowID = window.id
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
        isAppSwitcherPresented = false
        scheduleSave()
    }

    func close(_ id: UUID) {
        windows.removeAll(where: { $0.id == id })
        if activeWindowID == id {
            activeWindowID = windows.max(by: { $0.zIndex < $1.zIndex })?.id
        }
        if windows.isEmpty {
            isAppSwitcherPresented = false
        }
        scheduleSave()
    }

    func toggleMinimize(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].isMinimized.toggle()
        if windows[index].isMinimized, activeWindowID == id {
            activeWindowID = windows
                .filter { !$0.isMinimized }
                .max(by: { $0.zIndex < $1.zIndex })?.id
        }
        scheduleSave()
    }

    func moveActiveWindow(normalizedDelta: CGVector) {
        guard let activeWindowID else { return }
        moveWindow(activeWindowID, normalizedDelta: normalizedDelta)
    }

    func moveWindow(_ id: UUID, normalizedDelta: CGVector) {
        mutateWindow(id) { window in
            window.transform.yaw += Double(normalizedDelta.dx) * 32
            window.transform.pitch -= Double(normalizedDelta.dy) * 22
            window.transform.clamp()
        }
    }

    func scaleActiveWindow(by magnificationDelta: CGFloat) {
        mutateActiveWindow { window in
            let factor = Double(magnificationDelta)
            window.transform.width *= factor
            window.transform.height *= factor
            window.transform.clamp()
        }
    }

    func zoomActiveWindow(by magnificationDelta: CGFloat) {
        guard magnificationDelta.isFinite, magnificationDelta > 0 else { return }
        mutateActiveWindow { window in
            window.transform.virtualDistance /= Double(magnificationDelta)
            window.transform.clamp()
        }
    }

    func adjustWindowDistance(_ id: UUID, by delta: Double) {
        guard delta.isFinite else { return }
        mutateWindow(id) { window in
            window.transform.virtualDistance += delta
            window.transform.clamp()
        }
    }

    func setWindowDistance(_ id: UUID, to distance: Double) {
        guard distance.isFinite else { return }
        mutateWindow(id) { window in
            window.transform.virtualDistance = distance
            window.transform.clamp()
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
            windows[index].isMinimized = true
        }
        activeWindowID = nil
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

    func resetWorkspace() {
        windows = Self.defaultWindows
        activeWindowID = windows.last?.id
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
        window.transform.yaw = -headPose.yaw
        window.transform.pitch = headPose.pitch
        window.transform.clamp()
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
