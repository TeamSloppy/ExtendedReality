import AppIntents
import PhotosUI
import SwiftUI
import UIKit

struct BrowserControlsView: View {
    @Bindable var browser: BrowserWindowSession
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(browser.tabs) { tab in
                            HStack(spacing: 2) {
                                Button {
                                    browser.selectTab(tab.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: tab.session.isLoading ? "circle.dotted" : "globe")
                                        Text(tab.displayTitle)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: 150)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(tab.id == browser.activeTabID ? .isSelected : [])

                                Button("Close \(tab.displayTitle)", systemImage: "xmark") {
                                    browser.closeTab(tab.id)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .disabled(browser.tabs.count == 1)
                            }
                            .font(.caption)
                            .foregroundStyle(tab.id == browser.activeTabID ? .primary : .secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 32)
                            .background(
                                tab.id == browser.activeTabID
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                            .accessibilityIdentifier("browser.tab.\(tab.id.uuidString)")
                        }
                    }
                }

                Text(browser.tabCountLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("New Tab", systemImage: "plus") {
                    browser.addTab()
                }
                .labelStyle(.iconOnly)
                .disabled(!browser.canCreateTab)
                .accessibilityIdentifier("browser.newTab")
            }

            browserNavigationBar

            if browser.activeSession.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let error = browser.activeSession.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: browser.addressFocusRequest) { _, _ in
            isAddressFocused = true
        }
    }

    private var browserNavigationBar: some View {
        HStack {
            Button("Back", systemImage: "chevron.backward") { browser.goBack() }
                .disabled(!browser.activeSession.canGoBack)
            Button("Forward", systemImage: "chevron.forward") { browser.goForward() }
                .disabled(!browser.activeSession.canGoForward)
            TextField(
                "Address or search",
                text: Binding(
                    get: { browser.activeSession.address },
                    set: { browser.activeSession.address = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .focused($isAddressFocused)
            .onSubmit { browser.loadActive() }
            .accessibilityIdentifier("browser.address")
            Button("Go", systemImage: "arrow.right.circle.fill") { browser.loadActive() }
                .labelStyle(.iconOnly)
            Button("Reload", systemImage: "arrow.clockwise") { browser.reloadActive() }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("browser.reload")
        }
    }
}

struct WebSessionControlsView: View {
    @Bindable var session: BrowserSession

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Back", systemImage: "chevron.backward") { session.goBack() }
                    .disabled(!session.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { session.goForward() }
                    .disabled(!session.canGoForward)
                TextField("Address or search", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit { session.load() }
                Button("Go", systemImage: "arrow.right.circle.fill") { session.load() }
                    .labelStyle(.iconOnly)
                Button("Reload", systemImage: "arrow.clockwise") { session.reload() }
                    .labelStyle(.iconOnly)
            }
            if session.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MediaControlsView: View {
    let session: MediaSession
    @Binding var isImportingFile: Bool
    @Binding var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !session.isShowingPhotoLibrary {
                    Button("Back to Library", systemImage: "chevron.backward") {
                        session.showPhotoLibrary()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("gallery.showLibrary")
                }

                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .current
                ) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                Button("Files", systemImage: "folder") { isImportingFile = true }
                    .buttonStyle(.bordered)

                if let fileName = session.fileName {
                    Spacer()
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if session.isShowingPhotoLibrary {
                Picker(
                    "Media filter",
                    selection: Binding(
                        get: { session.photoLibraryFilter },
                        set: { session.setPhotoLibraryFilter($0) }
                    )
                ) {
                    ForEach(MediaLibraryFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.systemImage)
                            .tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("gallery.mediaFilter")
            }

            if session.isSpatialPhoto || session.isVideo {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        session.isSpatialPhoto ? "Spatial photo detected" : "Stereo presentation",
                        systemImage: session.isSpatialPhoto ? "view.3d" : "sparkles.rectangle.stack"
                    )
                        .font(.headline)
                        .foregroundStyle(.cyan)

                    Picker(
                        "Presentation",
                        selection: Binding(
                            get: { session.presentationMode },
                            set: { session.setPresentationMode($0) }
                        )
                    ) {
                        ForEach(session.availablePresentationModes) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("gallery.presentationMode")

                    if session.presentationMode == .sourceStereo {
                        Text("3D uses the full glasses display. Enable Full SBS (3840×1080) on the XREAL glasses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if session.presentationMode == .generatedStereo {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("3D strength")
                                Spacer()
                                Text(session.stereoDisparityPercent, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { session.stereoDisparityPercent },
                                    set: { session.setStereoDisparityPercent($0) }
                                ),
                                in: StereoDepthSettings.disparityPercentRange
                            )
                            .accessibilityIdentifier("gallery.stereoStrength")
                            Text("Enable Full SBS (3840×1080) on the XREAL glasses. Depth updates adapt automatically if the iPhone gets warm.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if session.generatedStereoStatus != .idle {
                        Label(
                            session.generatedStereoStatus.title,
                            systemImage: session.generatedStereoStatus.systemImage
                        )
                        .font(.caption)
                        .foregroundStyle(
                            session.generatedStereoStatus.isError ? Color.orange : Color.cyan
                        )
                        .accessibilityIdentifier("gallery.generatedStereoStatus")
                    }
                }
            }

            if session.isVideo {
                HStack {
                    Button("Back 10", systemImage: "gobackward.10") { session.seek(seconds: -10) }
                    Spacer()
                    Button(
                        session.isPlaying ? "Pause" : "Play",
                        systemImage: session.isPlaying ? "pause.fill" : "play.fill"
                    ) { session.togglePlayback() }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Forward 10", systemImage: "goforward.10") { session.seek(seconds: 10) }
                }
            }

            if let error = session.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct YouTubeControlsView: View {
    @Bindable var session: YouTubeSession
    let apiClient: YouTubeAPIClient
    @AppStorage("youtube.apiKey") private var apiKey = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("YouTube URL, video ID, or search", text: $session.query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .onSubmit(submit)
                Button("Open", systemImage: "magnifyingglass", action: submit)
                    .buttonStyle(.borderedProminent)
            }

            if session.isSearching { ProgressView().controlSize(.small) }
            if let errorMessage = session.searchErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage = session.playerErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !session.results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(session.results) { video in
                            Button {
                                session.load(video: video)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AsyncImage(url: video.thumbnailURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.gray.opacity(0.2)
                                    }
                                    .frame(width: 150, height: 84)
                                    .clipped()
                                    Text(video.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .frame(width: 150, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Button("Back 10", systemImage: "gobackward.10") { session.seek(seconds: -10) }
                Spacer()
                Button(
                    session.isPlaying ? "Pause" : "Play",
                    systemImage: session.isPlaying ? "pause.fill" : "play.fill"
                ) { session.isPlaying ? session.pause() : session.play() }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Forward 10", systemImage: "goforward.10") { session.seek(seconds: 10) }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            session.configureSearch(apiClient: apiClient, apiKeyProvider: { apiKey })
        }
    }

    private func submit() {
        session.submitSearch()
    }
}

struct VNCControlsView: View {
    @Bindable var session: RoyalVNCSession

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Mac hostname or IP", text: $session.host)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                TextField("Port", value: $session.port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 82)
            }
            HStack {
                TextField("Username", text: $session.username)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $session.password)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(vncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.connectionState == .connected || session.connectionState == .connecting {
                    Button("Disconnect", role: .destructive) { session.disconnect() }
                } else {
                    Button("Connect", systemImage: "network") { session.connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var vncStatus: String {
        switch session.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .failed(let message): message
        }
    }
}

struct MapsControlsView: View {
    @Bindable var session: MapsSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Apple Maps route", systemImage: "map.fill")
                    .font(.headline)
                Spacer()
                Picker("Travel mode", selection: $session.transport) {
                    ForEach(MapsTransportMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Toggle("Start from current location", isOn: $session.usesCurrentLocation)

            if !session.usesCurrentLocation {
                TextField("Starting point", text: $session.sourceQuery)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.next)
                    .accessibilityIdentifier("maps.source")
            }

            HStack(spacing: 10) {
                TextField("Where to?", text: $session.destinationQuery)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.route)
                    .onSubmit { Task { await session.planRoute() } }
                    .accessibilityIdentifier("maps.destination")

                Button("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    Task { await session.planRoute() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(session.destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isLoading)
                .accessibilityIdentifier("maps.planRoute")
            }

            if session.isLoading {
                ProgressView("Building route with Apple Maps…")
                    .controlSize(.small)
            }

            if let errorMessage = session.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let summary = session.routeSummary {
                HStack(spacing: 10) {
                    Label(summary, systemImage: session.transport.systemImage)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let shareURL = session.shareURL {
                        ShareLink(item: shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("maps.shareRoute")
                    }
                    Button("Start in Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                        session.openInAppleMaps()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("maps.openInAppleMaps")
                }
            } else {
                Text("Choose a destination here, or share a route from Apple Maps to ExtendReality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MapsRoutePlannerSheet: View {
    let session: MapsSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MapsControlsView(session: session)
                    .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HeadPoseController.self) private var headPose
    @Environment(SystemDataStore.self) private var systemData
    @Environment(VoiceAssistantSettings.self) private var voiceSettings
    @Environment(VoiceAssistantCoordinator.self) private var voiceAssistant
    @Environment(WakeWordController.self) private var wakeWordController
    @AppStorage("youtube.apiKey") private var youtubeAPIKey = ""
    @AppStorage(RemoteDisplayLayout.defaultsKey) private var remoteDisplayLayout = RemoteDisplayLayout.single

    var body: some View {
        NavigationStack {
            Form {
                sloppyAssistantSection

                RemoteDisplayLayoutSettingsSection(selection: $remoteDisplayLayout)

                Section("YouTube Data API") {
                    SecureField("API key", text: $youtubeAPIKey)
                        .textInputAutocapitalization(.never)
                    Text("Search works after adding an API key. Google account OAuth additionally requires a Google iOS client ID and URL scheme in the project configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Tracking") {
                    LabeledContent("Provider", value: "AirPods Core Motion")
                    LabeledContent("Status", value: headPose.statusText)
                    HeadPoseReadout()
                    Button("Recenter Head Tracking", systemImage: "scope") {
                        headPose.recenter()
                    }
                    Text("Compatible AirPods provide 3DoF through CMHeadphoneMotionManager. Without them, the workspace automatically remains head-locked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Location", value: systemData.locationAuthorization.title)
                    if let location = systemData.location {
                        LabeledContent(
                            "Coordinates",
                            value: String(format: "%.4f, %.4f", location.latitude, location.longitude)
                        )
                        .monospacedDigit()
                    }
                    Button("Allow Location", systemImage: "location.fill") {
                        systemData.requestLocationAccess()
                    }
                    .disabled(systemData.locationAuthorization == .restricted || systemData.locationAuthorization == .unavailable)

                    LabeledContent("Health", value: systemData.healthAuthorization.title)
                    if let health = systemData.healthSummary {
                        LabeledContent("Today", value: "\(health.steps.formatted()) steps · \(Int(health.activeEnergyKilocalories.rounded())) kcal")
                    }
                    Button("Allow Health Data", systemImage: "heart.text.square.fill") {
                        Task { await systemData.requestHealthAccess() }
                    }
                    .disabled(systemData.healthAuthorization == .unavailable)

                    LabeledContent("Focus Status", value: focusStatusText)
                    Button("Allow Focus Status", systemImage: "moon.fill") {
                        systemData.requestFocusAccess()
                    }
                    .disabled(systemData.focusAuthorization == .restricted || systemData.focusAuthorization == .unavailable)

                    Button("Refresh Data", systemImage: "arrow.clockwise") {
                        Task { await systemData.refreshAll() }
                    }
                } header: {
                    Text("System Data")
                } footer: {
                    Text("Health access is read-only: today's steps, active energy, and latest heart rate. Location is requested only while ExtendReality is in use. Web apps also need their own per-app permission.")
                }

                if let error = systemData.lastErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var sloppyAssistantSection: some View {
        @Bindable var settings = voiceSettings
        return Section {
            Toggle("Enable Sloppy Assistant", isOn: $settings.isEnabled)
            TextField("Core URL", text: $settings.coreURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("Dashboard URL", text: $settings.dashboardURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            SecureField("Bearer token", text: $settings.authToken)
                .textInputAutocapitalization(.never)

            if voiceAssistant.availableAgents.isEmpty {
                TextField("Agent ID", text: $settings.agentID)
                    .textInputAutocapitalization(.never)
            } else {
                Picker("Agent", selection: $settings.agentID) {
                    ForEach(voiceAssistant.availableAgents) { agent in
                        Text(agent.displayName).tag(agent.id)
                    }
                }
            }

            Toggle("Share active window", isOn: $settings.sharesActiveContext)
            Toggle("Listen for “Sloppy”", isOn: $settings.wakeWordEnabled)
                .disabled(!settings.isEnabled)
                .accessibilityIdentifier("voiceAssistant.wakeWordEnabled")
            Label(wakeWordController.state.statusText, systemImage: wakeWordController.state.systemImage)
                .font(.caption)
                .foregroundStyle(wakeWordController.state.isListening ? .green : .secondary)
            if wakeWordController.state.opensSystemSettings {
                Button("Open System Settings", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            SiriTipView(intent: StartSloppyVoiceModeIntent())
            ShortcutsLink()
            Button("Test Sloppy Connection", systemImage: "network") {
                Task { await voiceAssistant.testConnection() }
            }
            Text(voiceAssistant.connectionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Sloppy Assistant")
        } footer: {
            Text("When enabled, ExtendReality listens on device for ‘Sloppy’ only while the app is active. Say the wake word, wait for Voice Mode to show Listening, then speak your request. Siri and Vocal Shortcuts remain available as optional alternatives.")
        }
    }

    private var focusStatusText: String {
        guard systemData.focusAuthorization == .authorized else {
            return systemData.focusAuthorization.title
        }
        return switch systemData.isFocused {
        case true: "Notifications silenced by Focus"
        case false: "Focus allows notifications"
        case nil: "Status unavailable"
        }
    }
}

private struct HeadPoseReadout: View {
    @Environment(HeadPoseController.self) private var headPose

    var body: some View {
        let pose = headPose.pose
        LabeledContent(
            "Pose",
            value: String(
                format: "yaw %.1f°  pitch %.1f°  roll %.1f°",
                pose.yaw,
                pose.pitch,
                pose.roll
            )
        )
        .monospacedDigit()
    }
}

#if DEBUG
#Preview("Browser Controls") {
    BrowserControlsView(
        browser: BrowserWindowSession(initialURL: "https://www.apple.com", loadsContent: false)
    )
    .padding()
}

#Preview("Media Controls") {
    MediaControlsView(
        session: MediaSession(),
        isImportingFile: .constant(false),
        selectedPhoto: .constant(nil)
    )
    .padding()
}

#Preview("YouTube Controls") {
    YouTubeControlsView(
        session: YouTubeSession(initialVideoID: nil, loadsContent: false),
        apiClient: YouTubeAPIClient()
    )
    .defaultAppStorage(PreviewFixtures.userDefaults)
    .padding()
}

#Preview("Remote Desktop Controls") {
    let environment = AppEnvironment.preview(windowCount: 0)
    let session = environment.surfaces.remoteDesktop(
        for: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        initialHost: "Mac-Studio.local"
    )
    VNCControlsView(session: session)
        .previewEnvironment(environment)
        .padding()
}

#Preview("Settings") {
    let environment = AppEnvironment.preview(windowCount: 0)
    SettingsView()
        .previewEnvironment(environment)
        .defaultAppStorage(PreviewFixtures.userDefaults)
}
#endif
