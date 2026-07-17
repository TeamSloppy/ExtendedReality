import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ControllerSheet: String, Identifiable {
    case controls
    var id: String { rawValue }
}

struct ControllerRootView: View {
    let environment: AppEnvironment
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(InputRouter.self) private var inputRouter
    @State private var inputMode: ControllerInputMode = .trackpad
    @State private var laserController = LaserPointerController()
    @State private var keyboardText = ""
    @State private var isImportingFile = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var presentedSheet: ControllerSheet?
    @FocusState private var isKeyboardFocused: Bool

    var body: some View {
        controllerContent
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.image, .movie, .video, .audiovisualContent]
        ) { result in
            guard let id = workspace.activeWindowID,
                  let session = environment.surfaces.mediaSession(for: id) as MediaSession? else { return }
            switch result {
            case .success(let url):
                do {
                    try session.importFile(url)
                } catch {
                    session.reportImportError(error)
                }
            case .failure(let error):
                session.reportImportError(error)
            }
        }
        .onChange(of: selectedPhoto, handleSelectedPhotoChange)
        .sheet(item: $presentedSheet) { _ in
            ControllerToolsSheet(
                environment: environment,
                isImportingFile: $isImportingFile,
                selectedPhoto: $selectedPhoto
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: inputMode, handleInputModeChange)
        .onChange(of: workspace.activeWindowID) { _, _ in
            environment.watchRemote.syncState()
        }
        .onChange(of: workspace.windows) { _, _ in
            environment.watchRemote.syncState()
        }
        .onDisappear {
            laserController.stop()
        }
    }

    private var controllerContent: some View {
        VStack(spacing: 14) {
            controllerHeader

            TrackpadView(
                workspace: workspace,
                inputRouter: inputRouter,
                mode: inputMode,
                laserController: laserController,
                onShowDashboard: environment.showDashboard,
                onShowWorkspace: environment.showWorkspace
            )
            .frame(maxHeight: .infinity)

            quickActionsDock
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private func handleSelectedPhotoChange(_ oldItem: PhotosPickerItem?, _ item: PhotosPickerItem?) {
        guard let item, let id = workspace.activeWindowID else { return }
        let session = environment.surfaces.mediaSession(for: id)
        let videoType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) })
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw MediaImportError.unavailablePhotoData
                }
                await MainActor.run {
                    do {
                        if let videoType {
                            try session.importMediaData(
                                data,
                                filenameExtension: videoType.preferredFilenameExtension ?? "mov"
                            )
                        } else {
                            try session.loadPhotoData(data)
                        }
                    } catch {
                        session.reportImportError(error)
                    }
                    selectedPhoto = nil
                }
            } catch {
                await MainActor.run {
                    session.reportImportError(error)
                    selectedPhoto = nil
                }
            }
        }
    }

    private func handleInputModeChange(_ oldMode: ControllerInputMode, _ newMode: ControllerInputMode) {
        workspace.controlMode = .pointer
        ControllerHaptics.selection()
        if newMode == .laser {
            laserController.start(workspace: workspace, inputRouter: inputRouter)
        } else {
            laserController.stop()
        }
    }

    private var controllerHeader: some View {
        HStack(spacing: 12) {
            Button {
                ControllerHaptics.click()
                presentedSheet = .controls
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .accessibilityLabel("Controls")
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(workspace.isExternalDisplayConnected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    .accessibilityHidden(true)
            }

            Picker("Input mode", selection: $inputMode) {
                ForEach(ControllerInputMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(height: 50)
            .accessibilityIdentifier("inputMode")
        }
    }

    private var quickActionsDock: some View {
        HStack(spacing: 10) {
            keyboardDock

            if workspace.activeWindow?.kind == .gallery {
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .current
                ) {
                    ControllerQuickActionLabel(
                        title: "Media",
                        systemImage: "photo.badge.plus"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose photo or video")
                .accessibilityIdentifier("gallery.importMedia")
            }

            ControllerQuickActionButton(
                title: "Center",
                systemImage: "scope"
            ) {
                environment.centerActiveWindow()
                ControllerHaptics.click()
            }
            .disabled(workspace.activeWindow == nil)
            .accessibilityIdentifier("workspace.center")

            ControllerQuickActionButton(
                title: "Apps",
                systemImage: "square.stack.3d.up.fill",
                isSelected: workspace.isAppSwitcherPresented,
                badge: workspace.windows.count
            ) {
                environment.toggleAppSwitcher()
                ControllerHaptics.selection()
            }
            .disabled(workspace.windows.isEmpty)
            .accessibilityIdentifier("workspace.appSwitcher")
        }
    }

    private var keyboardDock: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Keyboard", text: $keyboardText)
                .focused($isKeyboardFocused)
                .submitLabel(.send)
                .onSubmit(sendKeyboardText)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        ControllerHaptics.selection()
                    }
                )

            if !keyboardText.isEmpty {
                Button("Send", systemImage: "paperplane.fill", action: sendKeyboardText)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("keyboard.send")
            }
        }
        .font(.headline)
        .padding(.horizontal, 18)
        .frame(minHeight: 76)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.11), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private func sendKeyboardText() {
        guard !keyboardText.isEmpty else { return }
        inputRouter.insertText(keyboardText, in: workspace.activeWindowID)
        keyboardText = ""
        ControllerHaptics.click()
    }
}

private struct ControllerQuickActionButton: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControllerQuickActionLabel(
                title: title,
                systemImage: systemImage,
                isSelected: isSelected,
                badge: badge
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ControllerQuickActionLabel: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var badge: Int?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isSelected ? Color.cyan : Color.primary)
        .frame(width: 72, height: 76)
        .background(
            isSelected
                ? Color.cyan.opacity(0.14)
                : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isSelected ? Color.cyan.opacity(0.7) : .white.opacity(0.11), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(.cyan, in: Capsule())
                    .offset(x: 4, y: -4)
            }
        }
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct ControllerToolsSheet: View {
    private enum Destination: String, Identifiable {
        case settings
        case dashboard
        case pwaStore

        var id: String { rawValue }
    }

    let environment: AppEnvironment
    @Binding var isImportingFile: Bool
    @Binding var selectedPhoto: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(InputRouter.self) private var inputRouter
    @Environment(HeadPoseController.self) private var headPose
    @State private var destination: Destination?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionStatus
                    launcher
                    pwaStoreSection
                    dashboardSection
                    windowStrip

                    if let active = workspace.activeWindow {
                        activeHeader(active)
                        modeControls
                        windowDistanceControls(active)
                        ActiveWindowControls(
                            window: active,
                            environment: environment,
                            isImportingFile: $isImportingFile,
                            selectedPhoto: $selectedPhoto
                        )
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        ControllerHaptics.selection()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gear") {
                        ControllerHaptics.selection()
                        destination = .settings
                    }
                }
            }
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .settings:
                SettingsView()
            case .dashboard:
                DashboardEditorView(dashboard: environment.dashboard)
            case .pwaStore:
                PWAStoreView(environment: environment)
            }
        }
        .alert("Mac connection failed", isPresented: macConnectionErrorPresented) {
            Button("OK") {
                environment.macStreamClient.dismissError()
            }
        } message: {
            if case .failed(let message) = environment.macStreamClient.state {
                Text(message)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: workspace.isExternalDisplayConnected ? "eyeglasses" : "cable.connector")
                .font(.title2)
                .foregroundStyle(workspace.isExternalDisplayConnected ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.isExternalDisplayConnected ? "XREAL display connected" : "Connect XREAL by USB-C")
                    .font(.headline)
                Text("Tracking: \(headPose.statusText)")
                    .font(.caption)
                    .foregroundStyle(headPose.isTracking ? Color.green : Color.secondary)
                Text(environment.watchRemote.statusText)
                    .font(.caption2)
                    .foregroundStyle(environment.watchRemote.isWatchReachable ? Color.green : Color.secondary)
            }
            Spacer()
            Button("Reset", systemImage: "scope") {
                workspace.recenter()
                inputRouter.resetCursor()
                headPose.recenter()
                ControllerHaptics.click()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(WindowKind.allCases) { kind in
                    Button {
                        if kind == .remoteDesktop {
                            Task { await environment.openMacStream() }
                        } else {
                            environment.openWindow(kind)
                            ControllerHaptics.click()
                        }
                    } label: {
                        VStack(spacing: 8) {
                            if kind == .remoteDesktop, environment.macStreamClient.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: kind.systemImage)
                                    .font(.title2)
                            }
                            Text(kind.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 70)
                    }
                    .buttonStyle(.bordered)
                    .disabled(kind == .remoteDesktop && environment.macStreamClient.isBusy)
                    .accessibilityIdentifier("launcher.\(kind.rawValue)")
                }
            }
            if let status = environment.macStreamClient.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(macConnectionStatusColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var macConnectionErrorPresented: Binding<Bool> {
        Binding(
            get: {
                if case .failed = environment.macStreamClient.state { return true }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    environment.macStreamClient.dismissError()
                }
            }
        )
    }

    private var macConnectionStatusColor: Color {
        switch environment.macStreamClient.state {
        case .connected: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private var dashboardSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dashboard")
                    .font(.headline)
                Text("\(environment.dashboard.launchers.count) shortcuts · \(environment.dashboard.widgets.count) widgets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Customize", systemImage: "slider.horizontal.3") {
                destination = .dashboard
                ControllerHaptics.selection()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var pwaStoreSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Web App Store")
                    .font(.headline)
                Text("\(environment.pwaStore.installations.count) installed · curated catalog")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open", systemImage: "chevron.right") {
                destination = .pwaStore
                ControllerHaptics.selection()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var windowStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(workspace.windows.sorted(by: { $0.zIndex > $1.zIndex })) { window in
                    Button {
                        workspace.focus(window.id)
                        ControllerHaptics.selection()
                    } label: {
                        Label(window.title, systemImage: window.systemImage)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(workspace.activeWindowID == window.id ? .cyan : .gray)
                }
            }
        }
    }

    private func activeHeader(_ window: WorkspaceWindow) -> some View {
        HStack {
            Label(window.title, systemImage: window.systemImage)
                .font(.headline)
            Spacer()
            Button("Minimize", systemImage: "minus") {
                workspace.toggleMinimize(window.id)
                ControllerHaptics.selection()
            }
            .labelStyle(.iconOnly)
            Button("Close", systemImage: "xmark") {
                environment.closeWindow(window.id)
                ControllerHaptics.click()
            }
            .labelStyle(.iconOnly)
            .tint(.red)
        }
    }

    private var modeControls: some View {
        HStack {
            Picker("Mode", selection: Bindable(workspace).controlMode) {
                ForEach(ControlMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: workspace.controlMode) { _, _ in
                ControllerHaptics.selection()
            }

            Button("Back", systemImage: "chevron.backward") {
                inputRouter.back(in: workspace.activeWindowID)
                ControllerHaptics.click()
            }
            .labelStyle(.iconOnly)

            Button("Click", systemImage: "cursorarrow.click") {
                inputRouter.pointerDown(in: workspace.activeWindowID)
                inputRouter.pointerUp(in: workspace.activeWindowID)
                ControllerHaptics.click()
            }
            .labelStyle(.iconOnly)
        }
    }

    private func windowDistanceControls(_ window: WorkspaceWindow) -> some View {
        let range = WindowTransform3DoF.virtualDistanceRange
        let distance = workspace.windows
            .first(where: { $0.id == window.id })?
            .transform.virtualDistance ?? window.transform.virtualDistance
        let progress = (distance - range.lowerBound) / (range.upperBound - range.lowerBound)
        let percentage = Int((progress * 100).rounded())

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Window distance", systemImage: "viewfinder")
                    .font(.headline)
                Spacer()
                Text("\(percentage)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Closer", systemImage: "plus.magnifyingglass") {
                    workspace.adjustWindowDistance(window.id, by: -0.15)
                    ControllerHaptics.selection()
                }
                .buttonStyle(.bordered)

                Slider(
                    value: Binding(
                        get: {
                            workspace.windows
                                .first(where: { $0.id == window.id })?
                                .transform.virtualDistance ?? distance
                        },
                        set: { workspace.setWindowDistance(window.id, to: $0) }
                    ),
                    in: range
                )
                .accessibilityLabel("Window distance")
                .accessibilityValue("\(percentage) percent")

                Button("Farther", systemImage: "minus.magnifyingglass") {
                    workspace.adjustWindowDistance(window.id, by: 0.15)
                    ControllerHaptics.selection()
                }
                .buttonStyle(.bordered)
            }

            Text("You can also pinch anywhere on the trackpad.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ActiveWindowControls: View {
    let window: WorkspaceWindow
    let environment: AppEnvironment
    @Binding var isImportingFile: Bool
    @Binding var selectedPhoto: PhotosPickerItem?

    var body: some View {
        switch window.source {
        case .browser:
            BrowserControlsView(session: environment.surfaces.browser(for: window.id))
        case .pwa(let installation, let displayMode):
            BrowserControlsView(
                session: environment.surfaces.pwa(
                    for: window.id,
                    installation: installation,
                    displayMode: displayMode
                )
            )
        case .gallery:
            MediaControlsView(
                session: environment.surfaces.mediaSession(for: window.id),
                isImportingFile: $isImportingFile,
                selectedPhoto: $selectedPhoto
            )
        case .youtube:
            YouTubeControlsView(
                session: environment.surfaces.youtubeSession(for: window.id),
                apiClient: environment.youtubeAPI
            )
        case .remoteDesktop(let address):
            if let address, SurfaceRegistry.isWebStreamAddress(address) {
                BrowserControlsView(
                    session: environment.surfaces.macStream(for: window.id, initialURL: address)
                )
            } else {
                VNCControlsView(session: environment.surfaces.remoteDesktop(for: window.id))
            }
        }
    }
}

#if DEBUG
#Preview("Controller — Active Window") {
    let environment = AppEnvironment.preview()
    ControllerRootView(environment: environment)
        .previewEnvironment(environment)
}

#Preview("Controller — Dashboard") {
    let environment = AppEnvironment.preview(windowCount: 0, showsDashboard: true)
    ControllerRootView(environment: environment)
        .previewEnvironment(environment)
}

#Preview("Controls Sheet") {
    let environment = AppEnvironment.preview()
    ControllerToolsSheet(
        environment: environment,
        isImportingFile: .constant(false),
        selectedPhoto: .constant(nil)
    )
    .previewEnvironment(environment)
}
#endif
