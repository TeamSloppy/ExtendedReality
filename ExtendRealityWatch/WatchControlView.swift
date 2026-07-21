import SwiftUI

struct WatchControlView: View {
    let controller: WatchControlModel
    @State private var crownValue = 0.0
    @State private var previousCrownValue = 0.0
    @FocusState private var crownFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 7) {
                statusHeader
                if let playback = controller.activePlayback {
                    playbackControls(playback)
                } else {
                    pointerButton
                    clickButton
                }
                actionRow
            }
            .padding(.horizontal, 8)
            .containerBackground(
                LinearGradient(
                    colors: [.black, Color(red: 0.02, green: 0.12, blue: 0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                for: .navigation
            )
            .focusable()
            .focused($crownFocused)
            .digitalCrownRotation(
                $crownValue,
                from: -10_000,
                through: 10_000,
                sensitivity: .medium,
                isContinuous: true,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: crownValue) { _, newValue in
                controller.scroll(crownDelta: newValue - previousCrownValue)
                previousCrownValue = newValue
            }
            .onAppear {
                crownFocused = true
                controller.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        RemoteMenuView(controller: controller)
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .accessibilityLabel("Apps and windows")
                }
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(controller.isReachable ? .green : .orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(controller.activeWindow?.title ?? "No window")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(controller.connectionText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var pointerButton: some View {
        Button {
            controller.togglePointer()
        } label: {
            ZStack {
                Circle()
                    .fill(controller.isPointerActive ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08))
                Circle()
                    .stroke(controller.isPointerActive ? Color.cyan : Color.white.opacity(0.18), lineWidth: 2)
                Image(systemName: controller.isPointerActive ? "cursorarrow.motionlines" : "gyroscope")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(controller.isPointerActive ? .cyan : .white)
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
        .disabled(!controller.motionAvailable)
        .accessibilityLabel(controller.isPointerActive ? "Stop pointer" : "Start pointer")
        .accessibilityHint("Uses wrist motion to move the pointer")
    }

    private var clickButton: some View {
        Button {
            controller.click()
        } label: {
            Label("Click", systemImage: "cursorarrow.click")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .disabled(!controller.isReachable || controller.activeWindow == nil)
    }

    private func playbackControls(_ playback: WatchPlaybackState) -> some View {
        VStack(spacing: 5) {
            Text(playback.isPlaying ? "Now playing" : "Video paused")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                Button {
                    controller.seekPlayback(seconds: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("Back 10 seconds")

                Button {
                    controller.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .accessibilityLabel(playback.isPlaying ? "Pause video" : "Play video")

                Button {
                    controller.seekPlayback(seconds: 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("Forward 10 seconds")
            }
            .buttonStyle(.bordered)
        }
        .disabled(!controller.isReachable)
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            Button {
                controller.toggleVoiceAssistant()
            } label: {
                Image(systemName: controller.isVoiceAssistantActive ? "stop.fill" : "microphone.fill")
            }
            .tint(controller.isVoiceAssistantActive ? .orange : .purple)
            .handGestureShortcut(.primaryAction, isEnabled: controller.isReachable)
            .accessibilityLabel(controller.isVoiceAssistantActive ? "Stop voice assistant" : "Start voice assistant")
            .accessibilityHint("Activated by the system Double Tap gesture")

            Button {
                controller.recenter()
            } label: {
                Image(systemName: "scope")
            }
            .accessibilityLabel("Recenter")

            Button {
                controller.back()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Back")
        }
        .buttonStyle(.bordered)
        .disabled(!controller.isReachable)
    }
}

private struct RemoteMenuView: View {
    let controller: WatchControlModel

    var body: some View {
        List {
            Section("Windows") {
                if controller.snapshot.windows.isEmpty {
                    Text("No open windows")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.snapshot.windows) { window in
                        NavigationLink {
                            WindowActionsView(controller: controller, window: window)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(window.title).lineLimit(1)
                                    if window.id == controller.snapshot.activeWindowID {
                                        Text("Active").font(.caption2).foregroundStyle(.cyan)
                                    }
                                }
                            } icon: {
                                Image(systemName: symbol(for: window.kind))
                            }
                        }
                    }
                }
            }

            Section("Open app") {
                appButton(title: "Browser", symbol: "safari", kind: "browser")
                appButton(title: "Maps", symbol: "map.fill", kind: "maps")
                appButton(title: "Gallery", symbol: "photo.on.rectangle.angled", kind: "gallery")
                appButton(title: "YouTube", symbol: "play.rectangle.fill", kind: "youtube")
                appButton(title: "Mac", symbol: "desktopcomputer", kind: "remoteDesktop")
            }

            Section("Pointer") {
                Picker("Sensitivity", selection: Bindable(controller).sensitivity) {
                    Text("Low").tag(0.65)
                    Text("Normal").tag(1.0)
                    Text("High").tag(1.45)
                }
                Toggle("Invert vertical", isOn: Bindable(controller).invertVertical)
            }
        }
        .navigationTitle("Control")
    }

    private func appButton(title: String, symbol: String, kind: String) -> some View {
        Button {
            controller.open(kind: kind)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "browser": "safari"
        case "maps": "map.fill"
        case "gallery": "photo.on.rectangle.angled"
        case "youtube": "play.rectangle.fill"
        default: "desktopcomputer"
        }
    }
}

private struct WindowActionsView: View {
    let controller: WatchControlModel
    let window: WatchWindowSummary

    var body: some View {
        List {
            Button("Focus", systemImage: "scope") {
                controller.focus(window)
            }
            Button(window.isMinimized ? "Restore" : "Minimize", systemImage: "minus") {
                controller.minimize(window)
            }
            Button("Close", systemImage: "xmark", role: .destructive) {
                controller.close(window)
            }
        }
        .navigationTitle(window.title)
    }
}

#if DEBUG
#Preview("Watch Controller") {
    WatchControlView(controller: .preview())
}

#Preview("Watch Video Controls") {
    WatchControlView(controller: .preview(showsPlayback: true))
}

#Preview("Watch Apps and Windows") {
    NavigationStack {
        RemoteMenuView(controller: .preview())
    }
}

#Preview("Watch Window Actions") {
    let controller = WatchControlModel.preview()
    NavigationStack {
        WindowActionsView(
            controller: controller,
            window: controller.snapshot.windows[0]
        )
    }
}
#endif
