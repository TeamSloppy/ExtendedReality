import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class StudioAppModel {
    var selectedPreset: StudioPreset = .pwaLab
    var address = StudioPreset.pwaLab.defaultAddress
    var displayMode: PWADisplayMode = .window
    var grantedCapabilities = StudioPreset.pwaLab.defaultCapabilities
    var fixtures = StudioFixtureData()
    var layout: SpatialAppLayout
    var windowTransform = StudioWindowTransform()
    var logs: [StudioLogEntry] = []
    var isInspectorPresented = true
    var activePanelID: SpatialPanelID = .primary

    @ObservationIgnored private let websiteDataStore = WKWebsiteDataStore.default()
    @ObservationIgnored private var secondarySessions: [SpatialPanelID: StudioWebSession] = [:]

    @ObservationIgnored
    private(set) lazy var primarySession = makeSession(isPrimary: true)

    init() {
        layout = Self.defaultLayout(title: StudioPreset.pwaLab.title)
    }

    var serverCommand: String? { selectedPreset.serverCommand }

    var serverHint: String {
        if let serverCommand {
            "Run \(serverCommand) in another terminal, then press Launch. Vite HMR updates the viewport automatically."
        } else {
            "Enter a local HTTP or HTTPS address and press Launch."
        }
    }

    var activeSession: StudioWebSession {
        session(for: activePanelID) ?? primarySession
    }

    func selectPreset(_ preset: StudioPreset) {
        guard selectedPreset != preset else { return }
        selectedPreset = preset
        address = preset.defaultAddress
        grantedCapabilities = preset.defaultCapabilities
        resetSpatialLayout()
        appendLog(.info, source: "studio", message: "Selected \(preset.title)")
    }

    func launch() {
        do {
            let url = try StudioURL.resolve(address, displayMode: displayMode)
            resetSpatialLayout()
            primarySession.load(url)
            activePanelID = layout.primaryPanelID
            appendLog(.info, source: "runtime", message: "Loading \(url.absoluteString)")
        } catch {
            appendLog(.error, source: "runtime", message: error.localizedDescription)
        }
    }

    func reload() {
        primarySession.reload()
        for session in secondarySessions.values {
            session.reload()
        }
        appendLog(.info, source: "runtime", message: "Reloaded all panels")
    }

    func setDisplayMode(_ mode: PWADisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        launch()
    }

    func toggleInspector() {
        isInspectorPresented.toggle()
    }

    func resetSpatialLayout() {
        layout = Self.defaultLayout(title: selectedPreset.title)
        secondarySessions.removeAll()
        activePanelID = layout.primaryPanelID
    }

    func resetTransform() {
        windowTransform = StudioWindowTransform()
    }

    func moveWindow(from initial: StudioWindowTransform, translation: CGSize, viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        var next = initial
        next.yaw += Double(translation.width / viewport.width) * 84
        next.pitch -= Double(translation.height / viewport.height) * 48
        next.clamp()
        windowTransform = next
    }

    func scaleWindow(from initial: StudioWindowTransform, translation: CGSize) {
        var next = initial
        next.scale *= exp(Double(translation.width - translation.height) / 360)
        next.clamp()
        windowTransform = next
    }

    func adjustScale(by factor: Double) {
        windowTransform.scale *= factor
        windowTransform.clamp()
    }

    func adjustDistance(by delta: Double) {
        windowTransform.distance += delta
        windowTransform.clamp()
    }

    func focusNextPanel() {
        let ids = layout.panels.map(\.id)
        guard !ids.isEmpty else { return }
        let nextIndex = ids.firstIndex(of: activePanelID)
            .map { ids.index(after: $0) }
            .map { $0 == ids.endIndex ? ids.startIndex : $0 }
            ?? ids.startIndex
        activePanelID = ids[nextIndex]
        session(for: activePanelID)?.focus()
    }

    func focus(_ panelID: SpatialPanelID) {
        activePanelID = panelID
        session(for: panelID)?.focus()
    }

    func session(for panelID: SpatialPanelID) -> StudioWebSession? {
        if panelID == layout.primaryPanelID { return primarySession }
        return secondarySessions[panelID]
    }

    func setCapability(_ capability: PWACapability, isGranted: Bool) {
        if isGranted {
            grantedCapabilities.insert(capability)
        } else {
            grantedCapabilities.remove(capability)
            if capability == .spatialWindows {
                resetSpatialLayout()
            }
        }
        appendLog(
            .info,
            source: "permissions",
            message: "\(capability.title): \(isGranted ? "granted" : "denied")"
        )
    }

    func clearLogs() {
        logs.removeAll()
    }

    func copyServerCommand() {
        guard let serverCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverCommand, forType: .string)
        appendLog(.info, source: "studio", message: "Copied server command")
    }

    func clearWebsiteData() async {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await websiteDataStore.dataRecords(ofTypes: dataTypes)
        await websiteDataStore.removeData(ofTypes: dataTypes, for: records)
        appendLog(.info, source: "storage", message: "Cleared WebKit website data")
        launch()
    }

    private func applyLayout(_ requestedLayout: SpatialAppLayout?) throws {
        let nextLayout = try (requestedLayout ?? Self.defaultLayout(title: selectedPreset.title))
            .validated(permitsPrevalidatedWebContent: true)
        layout = nextLayout
        reconcileSecondarySessions()
        if !nextLayout.panels.contains(where: { $0.id == activePanelID }) {
            activePanelID = nextLayout.primaryPanelID
        }
        appendLog(
            .info,
            source: "spatial",
            message: "Applied \(nextLayout.panels.count)-panel layout"
        )
    }

    private func reconcileSecondarySessions() {
        let secondaryPanels = layout.panels.filter { $0.id != layout.primaryPanelID }
        let liveIDs = Set(secondaryPanels.map(\.id))
        secondarySessions = secondarySessions.filter { liveIDs.contains($0.key) }

        for panel in secondaryPanels {
            guard case .web(let url) = panel.content else { continue }
            let session = secondarySessions[panel.id] ?? makeSession(isPrimary: false)
            secondarySessions[panel.id] = session
            if session.currentURL != url {
                session.load(url)
            }
        }
    }

    private func makeSession(isPrimary: Bool) -> StudioWebSession {
        StudioWebSession(
            isPrimary: isPrimary,
            websiteDataStore: websiteDataStore,
            capabilityProvider: { [weak self] capability in
                self?.grantedCapabilities.contains(capability) == true
            },
            dataProvider: { [weak self] capability in
                guard let self else { throw StudioHostError.unsupportedCapability(capability) }
                return try fixtures.payload(for: capability)
            },
            layoutProvider: { [weak self] in
                self?.layout ?? Self.defaultLayout(title: "PWA")
            },
            layoutHandler: { [weak self] layout in
                try self?.applyLayout(layout)
            },
            logHandler: { [weak self] level, source, message in
                self?.appendLog(level, source: source, message: message)
            }
        )
    }

    private func appendLog(_ level: StudioLogLevel, source: String, message: String) {
        logs.append(StudioLogEntry(date: .now, level: level, source: source, message: message))
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private static func defaultLayout(title: String) -> SpatialAppLayout {
        SpatialAppLayout(panels: [
            SpatialPanelDescriptor(
                id: .primary,
                accessibilityLabel: title,
                placement: SpatialPanelPlacement(width: 0.72, height: 0.68),
                content: .primary
            )
        ])
    }
}
