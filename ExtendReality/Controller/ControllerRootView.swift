import PhotosUI
import SwiftUI
import Translation
import UniformTypeIdentifiers

enum ControllerSheet: String, Identifiable {
    case controls
    case maps
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
        NavigationStack {
            controllerContent
        }
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
        .onChange(of: activeGallerySession?.fileImportRequest) { oldRequest, newRequest in
            guard newRequest != nil, newRequest != oldRequest else { return }
            isImportingFile = true
        }
        .sheet(item: $presentedSheet) { sheet in
            Group {
                switch sheet {
                case .controls:
                    ControllerToolsSheet(
                        environment: environment,
                        isImportingFile: $isImportingFile,
                        selectedPhoto: $selectedPhoto
                    )
                case .maps:
                    if let session = activeMapsSession {
                        MapsRoutePlannerSheet(session: session)
                    }
                }
            }
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
        .onChange(of: inputRouter.textInputFocusRequest) {
            keyboardText = inputRouter.textInputDraft
            isKeyboardFocused = true
        }
        .onChange(of: keyboardText) { _, newValue in
            guard newValue != inputRouter.textInputDraft else { return }
            inputRouter.replaceTextInput(newValue, in: workspace.activeWindowID)
        }
        .onChange(of: environment.voiceModeActivationRouter.pendingRequest?.id, initial: true) {
            _, requestID in
            guard let requestID else { return }
            environment.voiceAssistant.activate()
            environment.voiceModeActivationRouter.consume(requestID)
        }
        .onDisappear {
            laserController.stop()
            environment.handTracking.stop()
            environment.hardwareMouseInput.setCaptureEnabled(false)
        }
        .translationTask(
            source: environment.liveTranslation.sourceLanguage.translationLanguage,
            target: environment.liveTranslation.targetLanguage.translationLanguage
        ) { session in
            await environment.liveTranslation.consumeTranslations(using: session)
        }
    }

    private var controllerContent: some View {
        GeometryReader { proxy in
            if workspace.isExternalDisplayConnected {
                if proxy.size.width > proxy.size.height {
                    landscapeControllerContent
                        .toolbar(.hidden, for: .navigationBar)
                } else {
                    portraitControllerContent
                        .toolbar(.visible, for: .navigationBar)
                        .toolbar {
                            controllerHeader
                        }
                }
            } else {
                DeviceWorkspaceView(
                    environment: environment,
                    onShowControls: {
                        presentedSheet = .controls
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .overlay {
            if environment.hardwareMouseInput.isCaptureEnabled {
                mouseCaptureOverlay
            }
        }
    }

    private var portraitControllerContent: some View {
        VStack(spacing: 14) {
            wakeWordStatus

            trackpad

            quickActionsDock
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var landscapeControllerContent: some View {
        HStack(spacing: 12) {
            landscapeControlRail
                .frame(width: 180)

            ZStack(alignment: .top) {
                trackpad

                if environment.wakeWordController.state.isListening {
                    wakeWordStatus
                        .padding(.top, 10)
                        .padding(.horizontal, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var trackpad: some View {
        Group {
            if inputMode == .hands {
                IOSHandControlView(
                    controller: environment.handTracking,
                    isExternalDisplayConnected: workspace.isExternalDisplayConnected
                )
            } else {
                TrackpadView(
                    workspace: workspace,
                    dashboard: environment.dashboard,
                    inputRouter: inputRouter,
                    mode: inputMode,
                    laserController: laserController,
                    onShowDashboard: environment.toggleDashboard,
                    onCenterWindow: environment.centerActiveWindow
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var wakeWordStatus: some View {
        if environment.wakeWordController.state.isListening {
            Label(
                environment.wakeWordController.state.statusText,
                systemImage: environment.wakeWordController.state.systemImage
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.green.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("voiceAssistant.wakeWordListening")
        }
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
        if newMode == .hands {
            laserController.stop()
            environment.hardwareMouseInput.setCaptureEnabled(false)
            Task { await environment.handTracking.start() }
        } else if newMode == .laser {
            environment.handTracking.stop()
            laserController.start(workspace: workspace, inputRouter: inputRouter)
        } else {
            environment.handTracking.stop()
            laserController.stop()
        }
    }

    @ToolbarContentBuilder
    private var controllerHeader: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                ControllerHaptics.click()
                presentedSheet = .controls
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Controls")
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(workspace.isExternalDisplayConnected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    .accessibilityHidden(true)
            }
        }

        ToolbarItem(placement: .title) {
            Picker("Input mode", selection: $inputMode) {
                ForEach(ControllerInputMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsVisibility(.visible)
            .frame(height: 50)
            .accessibilityIdentifier("inputMode")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if inputMode == .hands { inputMode = .trackpad }
                environment.hardwareMouseInput.toggleCapture()
                ControllerHaptics.selection()
            } label: {
                Image(
                    systemName: environment.hardwareMouseInput.isCaptureEnabled
                    ? "cursorarrow.motionlines"
                    : "computermouse"
                )
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
            }
            .tint(environment.hardwareMouseInput.isCaptureEnabled ? .cyan : nil)
            .disabled(!environment.hardwareMouseInput.isMouseConnected)
            .accessibilityLabel(
                environment.hardwareMouseInput.isCaptureEnabled
                ? "Return mouse to iPad"
                : "Move mouse to XREAL display"
            )
            .accessibilityHint(
                environment.hardwareMouseInput.isMouseConnected
                ? "Captures the physical mouse for the spatial cursor"
                : "Connect a Bluetooth or USB mouse first"
            )
            .accessibilityIdentifier("hardwareMouse.toggleCapture")
        }
    }

    private var mouseCaptureOverlay: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 14) {
                Image(systemName: "display.and.cursorarrow")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.cyan)
                Text("Mouse is on the XREAL display")
                    .font(.headline)
                Text("Move, click, and scroll in the glasses. Press Esc or tap below to return to iPad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Return to iPad", systemImage: "ipad") {
                    environment.hardwareMouseInput.setCaptureEnabled(false)
                    ControllerHaptics.selection()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .accessibilityIdentifier("hardwareMouse.releaseCapture")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding()
        }
        .ignoresSafeArea()
    }

    private var quickActionsDock: some View {
        HStack(spacing: 10) {
            keyboardDock

            ControllerQuickActionButton(
                title: environment.voiceAssistant.actionTitle,
                systemImage: environment.voiceAssistant.actionSystemImage,
                isSelected: environment.voiceAssistant.state.phase.isPresented
            ) {
                environment.voiceAssistant.toggle()
                ControllerHaptics.click()
            }
            .disabled(!environment.voiceAssistantSettings.isEnabled)
            .accessibilityIdentifier("voiceAssistant.toggle")

            if let gallerySession = activeGallerySession {
                galleryQuickAction(for: gallerySession)
            }

            if activeMapsSession != nil {
                ControllerQuickActionButton(title: "Route", systemImage: "map.fill") {
                    presentedSheet = .maps
                    ControllerHaptics.selection()
                }
                .accessibilityIdentifier("maps.openRoutePlanner")
            }

            ControllerQuickActionButton(
                title: "Center",
                systemImage: "scope"
            ) {
                environment.centerActiveWindow()
                ControllerHaptics.click()
            }
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

    private var landscapeControlRail: some View {
        VStack(spacing: 8) {
            landscapeKeyboardDock

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ControllerRailActionButton(
                    title: "Controls",
                    systemImage: "slider.horizontal.3",
                    statusColor: workspace.isExternalDisplayConnected ? .green : .orange
                ) {
                    ControllerHaptics.click()
                    presentedSheet = .controls
                }
                .accessibilityIdentifier("controls.open")

                ControllerRailActionButton(
                    title: "Mouse",
                    systemImage: environment.hardwareMouseInput.isCaptureEnabled
                        ? "cursorarrow.motionlines"
                        : "computermouse",
                    isSelected: environment.hardwareMouseInput.isCaptureEnabled
                ) {
                    if inputMode == .hands { inputMode = .trackpad }
                    environment.hardwareMouseInput.toggleCapture()
                    ControllerHaptics.selection()
                }
                .disabled(!environment.hardwareMouseInput.isMouseConnected)
                .accessibilityLabel(
                    environment.hardwareMouseInput.isCaptureEnabled
                        ? "Return mouse to iPad"
                        : "Move mouse to XREAL display"
                )
                .accessibilityHint(
                    environment.hardwareMouseInput.isMouseConnected
                        ? "Captures the physical mouse for the spatial cursor"
                        : "Connect a Bluetooth or USB mouse first"
                )
                .accessibilityIdentifier("hardwareMouse.toggleCapture")

                ForEach(ControllerInputMode.allCases) { mode in
                    ControllerRailActionButton(
                        title: mode.title,
                        systemImage: mode.systemImage,
                        isSelected: inputMode == mode
                    ) {
                        inputMode = mode
                    }
                    .accessibilityIdentifier("inputMode.\(mode.rawValue)")
                }

                ControllerRailActionButton(
                    title: environment.voiceAssistant.actionTitle,
                    systemImage: environment.voiceAssistant.actionSystemImage,
                    isSelected: environment.voiceAssistant.state.phase.isPresented
                ) {
                    environment.voiceAssistant.toggle()
                    ControllerHaptics.click()
                }
                .disabled(!environment.voiceAssistantSettings.isEnabled)
                .accessibilityIdentifier("voiceAssistant.toggle")

                if let gallerySession = activeGallerySession {
                    galleryRailAction(for: gallerySession)
                }

                if activeMapsSession != nil {
                    ControllerRailActionButton(title: "Route", systemImage: "map.fill") {
                        presentedSheet = .maps
                        ControllerHaptics.selection()
                    }
                    .accessibilityIdentifier("maps.openRoutePlanner")
                }

                ControllerRailActionButton(
                    title: "Center",
                    systemImage: "scope"
                ) {
                    environment.centerActiveWindow()
                    ControllerHaptics.click()
                }
                .accessibilityIdentifier("workspace.center")

                ControllerRailActionButton(
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
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var landscapeKeyboardDock: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Keyboard", text: $keyboardText)
                .focused($isKeyboardFocused)
                .font(.caption.weight(.semibold))
                .submitLabel(.send)
                .onSubmit(sendKeyboardText)

            if !keyboardText.isEmpty {
                Button("Send", systemImage: "paperplane.fill", action: sendKeyboardText)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .accessibilityIdentifier("keyboard.send")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.11), lineWidth: 1)
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

    private var activeGallerySession: MediaSession? {
        guard let activeWindow = workspace.activeWindow,
              activeWindow.kind == .gallery else { return nil }
        return environment.surfaces.mediaSession(for: activeWindow.id)
    }

    private var activeMapsSession: MapsSession? {
        guard let activeWindow = workspace.activeWindow,
              activeWindow.kind == .maps else { return nil }
        return environment.surfaces.mapsSession(for: activeWindow.id)
    }

    @ViewBuilder
    private func galleryQuickAction(for session: MediaSession) -> some View {
        if session.isShowingPhotoLibrary {
            Menu {
                galleryFilterPicker(for: session)
                Divider()
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .current
                ) {
                    Label("Choose Media", systemImage: "photo.badge.plus")
                }
            } label: {
                ControllerQuickActionLabel(
                    title: session.photoLibraryFilter.title,
                    systemImage: session.photoLibraryFilter.systemImage,
                    isSelected: session.photoLibraryFilter != .all
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gallery filter")
            .accessibilityIdentifier("gallery.quickFilter")
        } else {
            ControllerQuickActionButton(
                title: "Library",
                systemImage: "chevron.backward"
            ) {
                session.showPhotoLibrary()
                ControllerHaptics.selection()
            }
            .accessibilityHint("Returns to the photo and video library")
            .accessibilityIdentifier("gallery.showLibrary")
        }
    }

    @ViewBuilder
    private func galleryRailAction(for session: MediaSession) -> some View {
        if session.isShowingPhotoLibrary {
            Menu {
                galleryFilterPicker(for: session)
                Divider()
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .current
                ) {
                    Label("Choose Media", systemImage: "photo.badge.plus")
                }
            } label: {
                ControllerRailActionLabel(
                    title: session.photoLibraryFilter.title,
                    systemImage: session.photoLibraryFilter.systemImage,
                    isSelected: session.photoLibraryFilter != .all
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gallery filter")
            .accessibilityIdentifier("gallery.quickFilter")
        } else {
            ControllerRailActionButton(
                title: "Library",
                systemImage: "chevron.backward"
            ) {
                session.showPhotoLibrary()
                ControllerHaptics.selection()
            }
            .accessibilityHint("Returns to the photo and video library")
            .accessibilityIdentifier("gallery.showLibrary")
        }
    }

    private func galleryFilterPicker(for session: MediaSession) -> some View {
        Picker(
            "Show",
            selection: Binding(
                get: { session.photoLibraryFilter },
                set: {
                    session.setPhotoLibraryFilter($0)
                    ControllerHaptics.selection()
                }
            )
        ) {
            ForEach(MediaLibraryFilter.allCases) { filter in
                Label(filter.title, systemImage: filter.systemImage)
                    .tag(filter)
            }
        }
    }

    private func sendKeyboardText() {
        guard !keyboardText.isEmpty else { return }
        inputRouter.submitTextInput(keyboardText, in: workspace.activeWindowID)
        inputRouter.clearTextInputDraft()
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

private struct ControllerRailActionButton: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var badge: Int?
    var statusColor: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControllerRailActionLabel(
                title: title,
                systemImage: systemImage,
                isSelected: isSelected,
                badge: badge,
                statusColor: statusColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ControllerRailActionLabel: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var badge: Int?
    var statusColor: Color?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(isSelected ? Color.cyan : Color.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            isSelected
                ? Color.cyan.opacity(0.14)
                : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? Color.cyan.opacity(0.7) : .white.opacity(0.11), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.cyan, in: Capsule())
                    .offset(x: 3, y: -3)
            } else if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    .offset(x: -7, y: 7)
            }
        }
        .opacity(isEnabled ? 1 : 0.42)
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
        case macSources
        case liveTranslation

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
                    macCursorSyncControls
                    captureControls
                    launcher
                    pwaStoreSection
                    liveTranslationSection
                    dashboardSection
                    windowStrip

                    if let active = workspace.activeWindow {
                        activeHeader(active)
                        modeControls
                        spatialLayoutControls(active)
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
            case .macSources:
                MacSourcePickerView(environment: environment)
            case .liveTranslation:
                LiveTranslationSettingsView(translation: environment.liveTranslation)
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
        .alert("Glasses capture failed", isPresented: captureErrorPresented) {
            Button("OK") {
                environment.externalDisplayCapture.dismissError()
            }
        } message: {
            if let message = environment.externalDisplayCapture.errorMessage {
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

    private var captureControls: some View {
        let capture = environment.externalDisplayCapture
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Glasses capture", systemImage: "rectangle.inset.filled.and.person.filled")
                    .font(.headline)
                Spacer()
                if capture.isRecording {
                    Label("REC", systemImage: "record.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 10) {
                Button("Screenshot", systemImage: "camera.fill") {
                    ControllerHaptics.click()
                    Task { await capture.captureScreenshot() }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!capture.isAttached || capture.state != .idle)
                .accessibilityIdentifier("externalDisplay.captureScreenshot")

                Button(
                    capture.isRecording ? "Stop" : "Record",
                    systemImage: capture.isRecording ? "stop.fill" : "record.circle"
                ) {
                    ControllerHaptics.click()
                    if capture.isRecording {
                        Task { await capture.stopRecording() }
                    } else {
                        capture.startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(capture.isRecording ? .red : .cyan)
                .frame(maxWidth: .infinity)
                .disabled(!capture.isAttached || capture.isBusy)
                .accessibilityIdentifier("externalDisplay.toggleRecording")

                if let url = capture.lastCaptureURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("externalDisplay.shareCapture")
                }
            }

            if let message = capture.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(capture.isRecording ? Color.red : Color.secondary)
            } else {
                Text("Captures the exact canvas rendered on the connected glasses display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var macCursorSyncControls: some View {
        Toggle(isOn: Binding(
            get: { environment.macStreamClient.isCursorSyncEnabled },
            set: { isEnabled in
                environment.setMacCursorSyncEnabled(isEnabled)
                ControllerHaptics.selection()
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Follow Mac cursor", systemImage: "cursorarrow.motionlines")
                    .font(.headline)
                Text("Shows the Mac pointer as the ExtendReality virtual cursor instead of embedding it in the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.cyan)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("macStream.cursorSync")
    }

    private var captureErrorPresented: Binding<Bool> {
        Binding(
            get: { environment.externalDisplayCapture.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    environment.externalDisplayCapture.dismissError()
                }
            }
        )
    }

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(WindowKind.allCases) { kind in
                    Button {
                        if kind == .remoteDesktop {
                            destination = .macSources
                            ControllerHaptics.selection()
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
            if let audioStatus = environment.macStreamClient.audioStatusText {
                Label(audioStatus, systemImage: "airpodspro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var liveTranslationSection: some View {
        HStack(spacing: 14) {
            Image(systemName: environment.liveTranslation.state.isActive ? "waveform.and.mic" : "captions.bubble.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live Translation")
                    .font(.headline)
                Text("\(environment.liveTranslation.languagePairLabel) · on-device subtitles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Configure", systemImage: "chevron.right") {
                destination = .liveTranslation
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

    private func spatialLayoutControls(_ window: WorkspaceWindow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Spatial layout", systemImage: "square.3.layers.3d")
                .font(.headline)

            Picker(
                "Workspace layout",
                selection: Binding(
                    get: { workspace.layoutMode },
                    set: { workspace.setLayoutMode($0, for: headPose.pose) }
                )
            ) {
                ForEach(WorkspaceLayoutMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workspace.layoutMode")

            Picker(
                "Window attachment",
                selection: Binding(
                    get: {
                        workspace.windows.first(where: { $0.id == window.id })?.attachmentMode
                            ?? window.attachmentMode
                    },
                    set: {
                        workspace.setAttachmentMode($0, for: window.id, headPose: headPose.pose)
                    }
                )
            ) {
                ForEach(WindowAttachmentMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(workspace.layoutMode == .stack)
            .accessibilityIdentifier("window.attachmentMode")

            Text(
                workspace.layoutMode == .stack
                    ? "Stack temporarily anchors every window. Drag horizontally to reorder, vertically to move the row, pinch to resize, and scroll to change its distance."
                    : "Anchor stays in world space. Smooth Follow eases the window toward your view. Follow keeps it locked to your view."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func windowDistanceControls(_ window: WorkspaceWindow) -> some View {
        let range = WindowTransform3DoF.virtualDistanceRange
        let distance = workspace.layoutMode == .stack
            ? workspace.stackTransform.virtualDistance
            : workspace.windows
                .first(where: { $0.id == window.id })?
                .transform.virtualDistance ?? window.transform.virtualDistance
        let progress = (distance - range.lowerBound) / (range.upperBound - range.lowerBound)
        let percentage = Int((progress * 100).rounded())

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    workspace.layoutMode == .stack ? "Stack distance" : "Window distance",
                    systemImage: "viewfinder"
                )
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
                            workspace.layoutMode == .stack
                                ? workspace.stackTransform.virtualDistance
                                : workspace.windows
                                    .first(where: { $0.id == window.id })?
                                    .transform.virtualDistance ?? distance
                        },
                        set: { workspace.setWindowDistance(window.id, to: $0) }
                    ),
                    in: range
                )
                .accessibilityLabel(workspace.layoutMode == .stack ? "Stack distance" : "Window distance")
                .accessibilityValue("\(percentage) percent")

                Button("Farther", systemImage: "minus.magnifyingglass") {
                    workspace.adjustWindowDistance(window.id, by: 0.15)
                    ControllerHaptics.selection()
                }
                .buttonStyle(.bordered)
            }

            Text("In Move mode, scroll anywhere on the trackpad to change distance.")
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
            BrowserControlsView(browser: environment.surfaces.browser(for: window.id))
        case .maps:
            MapsControlsView(session: environment.surfaces.mapsSession(for: window.id))
        case .pwa(let installation, let displayMode):
            WebSessionControlsView(
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
                session: environment.surfaces.youtubeSession(for: window.id)
            )
        case .remoteDesktop(let address):
            if let address, SurfaceRegistry.isWebStreamAddress(address) {
                WebSessionControlsView(
                    session: environment.surfaces.macStream(for: window.id, initialURL: address)
                )
            } else {
                VNCControlsView(session: environment.surfaces.remoteDesktop(for: window.id))
            }
        case .macCapture:
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Controller — Active Window") {
    let environment = AppEnvironment.preview()
    ControllerRootView(environment: environment)
        .previewEnvironment(environment)
}

#Preview("Controller — Active Window, landscape Left", traits: .landscapeLeft) {
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
