import Foundation
import SwiftUI
import SwiftData

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let modelContainer: ModelContainer
    let workspace: WorkspaceStore
    let dashboard: DashboardStore
    let pwaStore: PWAStore
    let systemData: SystemDataStore
    let inputRouter: InputRouter
    let hardwareMouseInput: HardwareMouseInput
    let surfaces: SurfaceRegistry
    let headPoseProvider: any HeadPoseProvider
    let headPose: HeadPoseController
    let watchRemote: WatchRemoteController
    let debugSocket: DebugSocketStreamer
    let keychain: KeychainStore
    let youtubeAPI: YouTubeAPIClient
    let macStreamClient: MacStreamClient
    let externalDisplayCapture: ExternalDisplayCaptureCoordinator
    let voiceAssistantSettings: VoiceAssistantSettings
    let voiceAssistant: VoiceAssistantCoordinator

    private let defaults: UserDefaults
    private var macStreamWindowIDsByEndpoint: [String: UUID] = [:]

    private init(
        storesDataInMemory: Bool = false,
        dashboardDefaults: UserDefaults = .standard,
        keychainService: String = "com.vladprusakov.ExtendReality",
        activatesWatchConnectivity: Bool = true
    ) {
        defaults = dashboardDefaults
        let schema = Schema([WorkspaceSnapshot.self])
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let primaryConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: storesDataInMemory || isRunningTests
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [primaryConfiguration])
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            modelContainer = try! ModelContainer(for: schema, configurations: [fallback])
        }

        let persistence = WorkspacePersistence(container: modelContainer)
        let workspace = WorkspaceStore(persistence: persistence)
        self.workspace = workspace
        dashboard = DashboardStore(defaults: dashboardDefaults)
        let pwaStore = PWAStore(defaults: dashboardDefaults)
        self.pwaStore = pwaStore
        let systemData = SystemDataStore(
            defaults: dashboardDefaults,
            loadsSystemData: !isRunningTests && !storesDataInMemory
        )
        self.systemData = systemData
        inputRouter = InputRouter()
        hardwareMouseInput = HardwareMouseInput(
            inputRouter: inputRouter,
            activeWindowID: { [weak workspace] in workspace?.activeWindowID },
            startsMonitoring: !isRunningTests && !storesDataInMemory
        )
        keychain = KeychainStore(service: keychainService)
        voiceAssistantSettings = VoiceAssistantSettings(defaults: dashboardDefaults, keychain: keychain)
        youtubeAPI = YouTubeAPIClient()
        macStreamClient = MacStreamClient()
        externalDisplayCapture = ExternalDisplayCaptureCoordinator()
        surfaces = SurfaceRegistry(
            inputRouter: inputRouter,
            workspace: workspace,
            keychain: keychain,
            pwaCapabilityProvider: { appID, capability in
                pwaStore.installation(for: appID)?.grants(capability) == true
            },
            pwaDataProvider: { capability in
                try systemData.pwaPayload(for: capability)
            }
        )
        let provider: any HeadPoseProvider = isRunningTests
            ? HeadLockedPoseProvider()
            : AirPodsHeadPoseProvider()
        headPoseProvider = provider
        headPose = HeadPoseController(provider: provider)
        voiceAssistant = VoiceAssistantCoordinator(
            settings: voiceAssistantSettings,
            workspace: workspace,
            contextProvider: surfaces,
            defaults: dashboardDefaults
        )
        watchRemote = WatchRemoteController(
            workspace: workspace,
            inputRouter: inputRouter,
            surfaces: surfaces,
            headPose: headPose,
            voiceAssistant: voiceAssistant,
            activatesSession: activatesWatchConnectivity && !isRunningTests
        )
        debugSocket = DebugSocketStreamer(
            workspace: workspace,
            headPose: headPose,
            watchRemote: watchRemote
        )
        macStreamClient.cursorPositionHandler = { [weak self] position in
            self?.applyMacCursorPosition(position)
        }
        voiceAssistant.onStateChange = { [weak self] in
            self?.watchRemote.syncState()
        }
        inputRouter.chromeActionHandler = { [weak self] windowID, action in
            switch action {
            case .toggleOrientation:
                self?.workspace.toggleLayoutOrientation(windowID)
            case .minimize:
                self?.minimizeWindow(windowID)
            case .toggleExpanded:
                guard let self else { return }
                workspace.toggleExpanded(windowID, for: headPose.pose)
            case .close:
                self?.closeWindow(windowID)
            }
        }
        inputRouter.dashboardActionHandler = { [weak self] itemID in
            self?.activateDashboardItem(itemID)
        }
        inputRouter.dashboardScrollHandler = { [weak dashboard] delta in
            dashboard?.consumePageScroll(delta)
        }
        inputRouter.statusBarActionHandler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .dashboard:
                showDashboard()
            case .pointerMode:
                workspace.controlMode = .pointer
            case .arrangeMode:
                workspace.controlMode = .arrange
            case .recenter:
                workspace.recenter()
                inputRouter.resetCursor()
                headPose.recenter()
            }
        }
        inputRouter.dockActionHandler = { [weak self] windowID in
            guard let self else { return }
            workspace.focus(windowID)
            inputRouter.setAppSwitcherPresented(false)
            watchRemote.syncState()
        }
        inputRouter.appSwitcherActionHandler = { [weak self] windowID in
            guard let self else { return }
            workspace.focusAndCenter(windowID, for: headPose.pose)
            inputRouter.setAppSwitcherPresented(false)
            inputRouter.resetCursor()
            watchRemote.syncState()
        }
        inputRouter.windowFocusHandler = { [weak self] windowID in
            guard let self else { return }
            workspace.focus(windowID)
            watchRemote.syncState()
        }
        inputRouter.panelFocusHandler = { [weak workspace] windowID, panelID in
            workspace?.focusPanel(panelID, in: windowID)
        }
        inputRouter.pointerHoverHandler = {
            ControllerHaptics.hover()
        }
        surfaces.prepare(for: workspace.windows)
    }

    @discardableResult
    func openWindow(_ kind: WindowKind) -> WorkspaceWindow {
        let window = workspace.addWindow(kind: kind)
        surfaces.prepare(for: [window])
        watchRemote.syncState()
        return window
    }

    func openMacStream() async {
        let storedLayout = defaults.string(forKey: RemoteDisplayLayout.defaultsKey)
            .flatMap(RemoteDisplayLayout.init(rawValue:)) ?? .single
        do {
            let session = try await macStreamClient.startStream(layout: storedLayout)
            replaceMacStreamWindows(with: session)
            ControllerHaptics.click()
        } catch {
            ControllerHaptics.error()
        }
    }

    func setMacCursorSyncEnabled(_ isEnabled: Bool) {
        let shouldRestart = macStreamClient.isConnected
        macStreamClient.setCursorSyncEnabled(isEnabled)
        if !isEnabled {
            inputRouter.hideCursor()
        }
        guard shouldRestart else { return }
        Task { @MainActor [weak self] in
            await self?.openMacStream()
        }
    }

    func closeWindow(_ id: UUID) {
        workspace.close(id)
        inputRouter.setAppSwitcherPresented(workspace.isAppSwitcherPresented)
        inputRouter.unregister(windowID: id)
        surfaces.remove(windowID: id)
        watchRemote.syncState()
    }

    func minimizeWindow(_ id: UUID) {
        workspace.toggleMinimize(id)
        watchRemote.syncState()
    }

    func showDashboard() {
        workspace.showDashboard()
        inputRouter.setAppSwitcherPresented(false)
        watchRemote.syncState()
    }

    func showWorkspace() {
        guard workspace.restoreMostRecentWindow() else { return }
        inputRouter.setAppSwitcherPresented(false)
        watchRemote.syncState()
    }

    func centerActiveWindow() {
        workspace.centerActiveWindow(for: headPose.pose)
        workspace.dismissAppSwitcher()
        inputRouter.setAppSwitcherPresented(false)
        inputRouter.resetCursor()
    }

    func toggleAppSwitcher() {
        workspace.toggleAppSwitcher()
        inputRouter.setAppSwitcherPresented(workspace.isAppSwitcherPresented)
        if workspace.isAppSwitcherPresented {
            inputRouter.resetCursor()
        }
    }

    @discardableResult
    func installPWA(
        _ manifest: PWAAppManifest,
        grantedCapabilities: Set<PWACapability>
    ) throws -> PWAInstallation {
        let installation = try pwaStore.install(
            manifest,
            grantedCapabilities: grantedCapabilities
        )
        dashboard.addPWA(installation)
        return installation
    }

    @discardableResult
    func openPWA(_ installation: PWAInstallation, displayMode: PWADisplayMode) -> WorkspaceWindow {
        let window = workspace.addWindow(
            title: installation.manifest.name,
            source: .pwa(installation, displayMode: displayMode)
        )
        surfaces.prepare(for: [window])
        watchRemote.syncState()
        return window
    }

    func uninstallPWA(_ appID: String) async throws {
        guard let installation = pwaStore.installation(for: appID) else { return }
        let windowIDs = workspace.windows.compactMap { window -> UUID? in
            if case .pwa(let installation, _) = window.source, installation.id == appID {
                return window.id
            }
            return nil
        }
        for windowID in windowIDs {
            closeWindow(windowID)
        }
        try await surfaces.removeWebsiteData(for: installation.dataStoreIdentifier)
        dashboard.removePWA(appID)
        pwaStore.uninstall(appID)
    }

    func setPWACapability(_ capability: PWACapability, granted: Bool, for appID: String) throws {
        try pwaStore.setCapability(capability, granted: granted, for: appID)
        guard capability == .spatialWindows, !granted else { return }
        for window in workspace.windows {
            guard case .pwa(let installation, _) = window.source, installation.id == appID else { continue }
            workspace.resetLayout(for: window.id)
            surfaces.removePanels(windowID: window.id)
        }
    }

    func activateDashboardItem(_ id: UUID) {
        guard let item = dashboard.item(id: id) else { return }
        switch item.content {
        case .app(let kind):
            if kind == .remoteDesktop {
                Task { await openMacStream() }
            } else {
                openWindow(kind)
            }
        case .pwa(let installation):
            let mode = installation.manifest.displayModes.contains(.window) ? PWADisplayMode.window : .widget
            openPWA(installation, displayMode: mode)
        case .bookmark(let bookmark):
            let window = workspace.addWindow(
                title: bookmark.title,
                source: .browser(url: bookmark.url)
            )
            surfaces.prepare(for: [window])
            watchRemote.syncState()
        case .widget(.focus):
            dashboard.toggleFocusTimer()
        case .widget(.calendar), .widget(.health):
            break
        }
    }

    private func replaceMacStreamWindows(with session: MacStreamSession) {
        let previousStreamIDs = workspace.windows.compactMap { window -> UUID? in
            guard case .remoteDesktop(let address) = window.source,
                  let address,
                  let scheme = URL(string: address)?.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { return nil }
            return window.id
        }
        macStreamWindowIDsByEndpoint = [:]
        previousStreamIDs.forEach(closeWindow)

        for endpoint in session.streams {
            let window = workspace.addWindow(
                title: endpoint.name,
                source: .remoteDesktop(host: endpoint.url.absoluteString),
                transform: .macStream,
                contentAspectRatio: endpoint.aspectRatio
            )
            macStreamWindowIDsByEndpoint[endpoint.id] = window.id
            surfaces.prepare(for: [window])
        }
        watchRemote.syncState()
    }

    private func applyMacCursorPosition(_ position: MacCursorPosition) {
        guard macStreamClient.isCursorSyncEnabled else { return }
        guard position.visible,
              let streamID = position.streamID,
              let x = position.x,
              let y = position.y,
              x.isFinite,
              y.isFinite,
              let windowID = macStreamWindowIDsByEndpoint[streamID] else {
            inputRouter.hideCursor()
            return
        }
        inputRouter.movePointer(
            toSurfacePosition: CGPoint(x: x, y: y),
            in: windowID
        )
    }
}

#if DEBUG
@MainActor
enum PreviewFixtures {
    static let userDefaults: UserDefaults = {
        let suiteName = "com.vladprusakov.ExtendReality.Previews"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()
}

@MainActor
extension AppEnvironment {
    static func preview(
        windowCount: Int = 1,
        showsDashboard: Bool = false,
        showsAppSwitcher: Bool = false
    ) -> AppEnvironment {
        let environment = AppEnvironment(
            storesDataInMemory: true,
            dashboardDefaults: PreviewFixtures.userDefaults,
            keychainService: "com.vladprusakov.ExtendReality.Previews",
            activatesWatchConnectivity: false
        )
        environment.workspace.isExternalDisplayConnected = true

        for index in 0 ..< windowCount {
            let window = environment.workspace.addWindow(
                title: index == 0 ? "Gallery" : "Gallery \(index + 1)",
                source: .gallery
            )
            environment.surfaces.prepare(for: [window])
        }

        if showsDashboard {
            environment.showDashboard()
        } else if showsAppSwitcher, windowCount > 0 {
            environment.toggleAppSwitcher()
        }
        return environment
    }
}

extension View {
    @MainActor
    func previewEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.workspace)
            .environment(environment.dashboard)
            .environment(environment.inputRouter)
            .environment(environment.headPose)
            .environment(environment.systemData)
            .environment(environment.voiceAssistant)
            .environment(environment.voiceAssistantSettings)
            .defaultAppStorage(PreviewFixtures.userDefaults)
    }
}
#endif
