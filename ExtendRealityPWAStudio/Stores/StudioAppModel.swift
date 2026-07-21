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
    var cameraTransform = StudioCameraTransform()
    var logs: [StudioLogEntry] = []
    var isInspectorPresented = true
    var activePanelID: SpatialPanelID = .primary
    var projectDirectory: URL?
    var packageScripts: [StudioPackageScript] = []
    var selectedPackageScriptName: String?
    var launchCommand = ""
    var projectIssue: StudioProjectIssue?

    @ObservationIgnored private let websiteDataStore = WKWebsiteDataStore.default()
    @ObservationIgnored private var secondarySessions: [SpatialPanelID: StudioWebSession] = [:]
    @ObservationIgnored private let projectAccess: StudioProjectAccess
    @ObservationIgnored private let bundledServer: BundledPWAHTTPServer?

    @ObservationIgnored
    private(set) lazy var primarySession = makeSession(isPrimary: true)

    init() {
        let projectAccess = StudioProjectAccess()
        self.projectAccess = projectAccess
        bundledServer = try? BundledPWAHTTPServer()
        layout = Self.defaultLayout(title: StudioPreset.pwaLab.title)
        launchCommand = projectAccess.storedCommand
        do {
            if let directory = try projectAccess.restoreDirectory() {
                configureProjectDirectory(directory, usesStoredCommand: true)
            }
        } catch {
            recordProjectIssue(error)
        }
    }

    var serverCommand: String? {
        if selectedPreset == .custom,
           let projectDirectory,
           !launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return StudioProjectCommand.fullCommand(
                directory: projectDirectory,
                command: launchCommand
            )
        }
        return selectedPreset.serverCommand
    }

    var serverHint: String {
        if selectedPreset.isBundled {
            return "The production PWA is included in the app. The copied command starts an optional Vite server for HMR development."
        }
        if serverCommand != nil {
            return "Run the copied command in Terminal, then press Launch. Framework HMR works when the selected server supports it."
        } else {
            return "Choose a project directory or enter a local HTTP or HTTPS address."
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

    func chooseProjectDirectory() {
        guard let directory = projectAccess.chooseDirectory() else { return }
        do {
            let activatedDirectory = try projectAccess.rememberAndActivate(directory)
            configureProjectDirectory(activatedDirectory, usesStoredCommand: false)
        } catch {
            recordProjectIssue(error)
        }
    }

    func setLaunchCommand(_ command: String) {
        launchCommand = command
        projectAccess.storedCommand = command
        selectedPackageScriptName = packageScripts.first(where: {
            "npm run \($0.name)" == command.trimmingCharacters(in: .whitespacesAndNewlines)
        })?.name
    }

    func selectPackageScript(_ scriptName: String?) {
        selectedPackageScriptName = scriptName
        guard let scriptName else { return }
        setLaunchCommand("npm run \(scriptName)")
    }

    func forgetProjectDirectory() {
        projectAccess.forgetDirectory()
        projectDirectory = nil
        packageScripts = []
        selectedPackageScriptName = nil
        launchCommand = ""
        projectIssue = nil
        if selectedPreset == .custom {
            address = StudioPreset.custom.defaultAddress
        }
        appendLog(.info, source: "project", message: "Forgot project directory")
    }

    func openProjectInTerminal() {
        guard let projectDirectory else { return }
        copyServerCommand()
        projectAccess.openInTerminal(projectDirectory) { [weak self] error in
            guard let self else { return }
            if let error {
                recordProjectIssue(error, source: "terminal")
            } else {
                appendLog(
                    .info,
                    source: "terminal",
                    message: "Opened \(projectDirectory.lastPathComponent); paste the copied command to run it"
                )
            }
        }
    }

    func launch() {
        if selectedPreset.isBundled,
           URL(string: address)?.scheme == BundledPWAResources.scheme {
            guard let bundledServer else {
                appendLog(.error, source: "runtime", message: BundledPWAHTTPServer.ServerError.missingResources.localizedDescription)
                return
            }
            let preset = selectedPreset
            Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await bundledServer.appURL(path: preset.bundledPath)
                    guard selectedPreset == preset else { return }
                    address = url.absoluteString
                    launchResolvedAddress()
                } catch {
                    appendLog(.error, source: "runtime", message: error.localizedDescription)
                }
            }
            return
        }
        launchResolvedAddress()
    }

    private func launchResolvedAddress() {
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

    func resetCamera() {
        cameraTransform = StudioCameraTransform()
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

    func rotateCamera(yaw: Double = 0, pitch: Double = 0) {
        cameraTransform.yaw += yaw
        cameraTransform.pitch += pitch
        cameraTransform.clamp()
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

    func copyProjectDiagnostics() {
        guard let projectIssue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(projectIssue.diagnostics, forType: .string)
        appendLog(.info, source: "project", message: "Copied project diagnostics")
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

    private func configureProjectDirectory(_ directory: URL, usesStoredCommand: Bool) {
        projectDirectory = directory
        selectedPreset = .custom
        grantedCapabilities = StudioPreset.custom.defaultCapabilities
        projectIssue = nil
        do {
            let inspection = try projectAccess.inspect(directory)
            packageScripts = inspection.scripts
            if !usesStoredCommand || launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let preferredScript = inspection.scripts.first(where: { $0.name == "dev" })
                    ?? inspection.scripts.first(where: { $0.name == "start" })
                    ?? inspection.scripts.first(where: { $0.name.localizedCaseInsensitiveContains("dev") })
                if let preferredScript {
                    selectPackageScript(preferredScript.name)
                } else if inspection.containsIndexHTML {
                    setLaunchCommand("python3 -m http.server 5173")
                }
            } else {
                selectedPackageScriptName = inspection.scripts.first(where: {
                    "npm run \($0.name)" == launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                })?.name
            }

            switch inspection.packageName?.lowercased() {
            case "pwa-lab":
                address = "http://127.0.0.1:5173/pwa-lab/"
            case "spatial-board":
                address = "http://127.0.0.1:5174/spatial-board/"
            case "spatial-video":
                address = "http://127.0.0.1:5175/spatial-video/"
            default:
                break
            }
            resetSpatialLayout()
            appendLog(
                .info,
                source: "project",
                message: "Opened \(directory.path); found \(inspection.scripts.count) package scripts"
            )
        } catch {
            packageScripts = []
            selectedPackageScriptName = nil
            recordProjectIssue(error)
        }
    }

    private func recordProjectIssue(_ error: Error, source: String = "project") {
        let issue = StudioProjectIssue(error: error)
        projectIssue = issue
        appendLog(.error, source: source, message: "\(issue.title)\n\(issue.diagnostics)")
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
