import PhotosUI
import SwiftUI

struct BrowserControlsView: View {
    @Bindable var session: BrowserSession

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Back", systemImage: "chevron.backward") { session.webView.goBack() }
                    .disabled(!session.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { session.webView.goForward() }
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
        HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .any(of: [.images, .videos])) {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            Button("Files", systemImage: "folder") { isImportingFile = true }
                .buttonStyle(.bordered)
            Spacer()
            Button("Back 10", systemImage: "gobackward.10") { session.seek(seconds: -10) }
                .labelStyle(.iconOnly)
            Button(
                session.isPlaying ? "Pause" : "Play",
                systemImage: session.isPlaying ? "pause.fill" : "play.fill"
            ) { session.togglePlayback() }
            .buttonStyle(.borderedProminent)
            Button("Forward 10", systemImage: "goforward.10") { session.seek(seconds: 10) }
                .labelStyle(.iconOnly)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct YouTubeControlsView: View {
    @Bindable var session: YouTubeSession
    let apiClient: YouTubeAPIClient
    @AppStorage("youtube.apiKey") private var apiKey = ""
    @State private var query = ""
    @State private var results: [YouTubeVideo] = []
    @State private var errorMessage: String?
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("YouTube URL, video ID, or search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .onSubmit(submit)
                Button("Open", systemImage: "magnifyingglass", action: submit)
                    .buttonStyle(.borderedProminent)
            }

            if isSearching { ProgressView().controlSize(.small) }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(results) { video in
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
    }

    private func submit() {
        errorMessage = nil
        if YouTubeVideoIDParser.parse(query) != nil {
            session.load(query)
            results = []
            return
        }
        isSearching = true
        Task {
            do {
                let found = try await apiClient.search(query: query, apiKey: apiKey)
                await MainActor.run {
                    results = found
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
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

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HeadPoseController.self) private var headPose
    @AppStorage("youtube.apiKey") private var youtubeAPIKey = ""

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
        session: BrowserSession(initialURL: "https://www.apple.com", loadsContent: false)
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
}
#endif
