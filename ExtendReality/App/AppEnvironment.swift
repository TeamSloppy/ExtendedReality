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
    let surfaces: SurfaceRegistry
    let headPoseProvider: any HeadPoseProvider
    let headPose: HeadPoseController
    let watchRemote: WatchRemoteController
    let debugSocket: DebugSocketStreamer
    let keychain: KeychainStore
    let youtubeAPI: YouTubeAPIClient

    private init(
        storesDataInMemory: Bool = false,
        dashboardDefaults: UserDefaults = .standard,
        keychainService: String = "com.vladprusakov.ExtendReality",
        activatesWatchConnectivity: Bool = true
    ) {
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
        workspace = WorkspaceStore(persistence: persistence)
        dashboard = DashboardStore(defaults: dashboardDefaults)
        let pwaStore = PWAStore(defaults: dashboardDefaults)
        self.pwaStore = pwaStore
        let systemData = SystemDataStore(
            defaults: dashboardDefaults,
            loadsSystemData: !isRunningTests && !storesDataInMemory
        )
        self.systemData = systemData
        inputRouter = InputRouter()
        keychain = KeychainStore(service: keychainService)
        youtubeAPI = YouTubeAPIClient()
        surfaces = SurfaceRegistry(
            inputRouter: inputRouter,
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
        watchRemote = WatchRemoteController(
            workspace: workspace,
            inputRouter: inputRouter,
            surfaces: surfaces,
            headPose: headPose,
            activatesSession: activatesWatchConnectivity && !isRunningTests
        )
        debugSocket = DebugSocketStreamer(
            workspace: workspace,
            headPose: headPose,
            watchRemote: watchRemote
        )
        inputRouter.chromeActionHandler = { [weak self] windowID, action in
            switch action {
            case .moveFarther:
                self?.workspace.adjustWindowDistance(windowID, by: 0.15)
            case .moveCloser:
                self?.workspace.adjustWindowDistance(windowID, by: -0.15)
            case .minimize:
                self?.minimizeWindow(windowID)
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
        inputRouter.appSwitcherActionHandler = { [weak self] windowID in
            guard let self else { return }
            workspace.focusAndCenter(windowID, for: headPose.pose)
            inputRouter.setAppSwitcherPresented(false)
            inputRouter.resetCursor()
            watchRemote.syncState()
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

    func activateDashboardItem(_ id: UUID) {
        guard let item = dashboard.item(id: id) else { return }
        switch item.content {
        case .app(let kind):
            openWindow(kind)
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
            .defaultAppStorage(PreviewFixtures.userDefaults)
    }
}
#endif
