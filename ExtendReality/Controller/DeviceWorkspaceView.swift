import SwiftUI

enum DeviceWorkspacePresentation: Equatable {
    case launcher
    case window(UUID)

    static func resolve(
        isDashboardPresented: Bool,
        presentationMode: WorkspacePresentationMode,
        activeWindow: WorkspaceWindow?
    ) -> Self {
        guard !isDashboardPresented,
              presentationMode == .windows,
              let activeWindow,
              !activeWindow.isMinimized else {
            return .launcher
        }
        return .window(activeWindow.id)
    }
}

struct DeviceWorkspaceView: View {
    let environment: AppEnvironment
    let onShowControls: () -> Void

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DashboardStore.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: DeviceWorkspacePresentation {
        .resolve(
            isDashboardPresented: workspace.isDashboardPresented,
            presentationMode: workspace.presentationMode,
            activeWindow: workspace.activeWindow
        )
    }

    var body: some View {
        Group {
            switch presentation {
            case .launcher:
                launcher
            case .window(let id):
                if let window = workspace.windows.first(where: { $0.id == id }) {
                    deviceWindow(window)
                } else {
                    launcher
                }
            }
        }
        .background(Color.black)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: presentation)
        .accessibilityIdentifier("deviceWorkspace")
    }

    private var launcher: some View {
        ZStack {
            DeviceWorkspaceBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    launcherHeader

                    if dashboard.applications.isEmpty {
                        ContentUnavailableView(
                            "No apps",
                            systemImage: "app.dashed",
                            description: Text("Install a web app or add an app from Controls.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .foregroundStyle(.white)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Apps")
                                    .font(.title3.bold())
                                    .foregroundStyle(.white)

                                Text("\(dashboard.applications.count)")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.62))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.white.opacity(0.09), in: Capsule())

                                Spacer()
                            }

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 146, maximum: 220), spacing: 14)],
                                spacing: 14
                            ) {
                                ForEach(dashboard.applications) { item in
                                    DeviceAppTile(item: item) {
                                        environment.activateDashboardItem(item.id)
                                        ControllerHaptics.click()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .safeAreaPadding(.top, 8)
        }
    }

    private var launcherHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("DEVICE MODE", systemImage: "iphone.gen3")
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.cyan)

                Spacer()
                openWindowsMenu

                Button {
                    onShowControls()
                    ControllerHaptics.selection()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.10), in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.14))
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Controls")
                .accessibilityIdentifier("deviceWorkspace.controls")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Your apps,\nready right here.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Open and use them on this device. When the glasses connect, your workspace moves with you.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: .orange.opacity(0.7), radius: 5)
                Text("Glasses offline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                Text("Running locally")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.105),
                    Color.cyan.opacity(0.045),
                    Color.white.opacity(0.055),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.38), radius: 24, y: 14)
    }

    private func deviceWindow(_ window: WorkspaceWindow) -> some View {
        VStack(spacing: 0) {
            deviceWindowBar(window)

            DeviceWindowSurface(window: window, environment: environment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private func deviceWindowBar(_ window: WorkspaceWindow) -> some View {
        HStack(spacing: 10) {
            Button {
                environment.showDashboard()
                ControllerHaptics.selection()
            } label: {
                Label("Apps", systemImage: "square.grid.2x2.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(.white.opacity(0.11), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.14)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityIdentifier("deviceWorkspace.apps")

            Menu {
                ForEach(workspace.windows.sorted(by: { $0.zIndex > $1.zIndex })) { candidate in
                    Button {
                        workspace.focus(candidate.id)
                        ControllerHaptics.selection()
                    } label: {
                        Label(candidate.title, systemImage: candidate.systemImage)
                    }
                }
            } label: {
                Label(window.title, systemImage: window.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .accessibilityLabel("Open windows")

            Spacer(minLength: 4)

            Button {
                onShowControls()
                ControllerHaptics.selection()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.11), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Controls")

            Button {
                environment.closeWindow(window.id)
                ControllerHaptics.click()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 40, height: 40)
                    .background(.red.opacity(0.18), in: Circle())
                    .overlay { Circle().strokeBorder(.red.opacity(0.22)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("deviceWorkspace.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.035, green: 0.045, blue: 0.065).opacity(0.98))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
    }

    private var openWindowsMenu: some View {
        Menu {
            if workspace.windows.isEmpty {
                Text("No open windows")
            } else {
                ForEach(workspace.windows.sorted(by: { $0.zIndex > $1.zIndex })) { window in
                    Button {
                        workspace.focus(window.id)
                        ControllerHaptics.selection()
                    } label: {
                        Label(window.title, systemImage: window.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.10), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14))
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(workspace.windows.isEmpty ? .white.opacity(0.28) : .white)
        .disabled(workspace.windows.isEmpty)
        .accessibilityLabel("Open windows")
    }
}

private struct DeviceWindowSurface: View {
    let window: WorkspaceWindow
    let environment: AppEnvironment

    var body: some View {
        switch window.source {
        case .browser:
            let browser = environment.surfaces.browser(for: window.id)
            VStack(spacing: 0) {
                BrowserControlsView(browser: browser)
                    .padding(8)
                BrowserSurfaceView(session: browser.activeSession)
            }
        default:
            SurfaceHostView(window: window, environment: environment)
        }
    }
}

private struct DeviceAppTile: View {
    let item: DashboardItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    LinearGradient(
                        colors: [accent.opacity(0.72), accent.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    icon
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(.white.opacity(0.22))
                }
                .shadow(color: accent.opacity(0.26), radius: 16, y: 8)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("Open on iPhone")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 146, alignment: .leading)
            .padding(16)
            .background(
                LinearGradient(
                    colors: [
                        accent.opacity(0.12),
                        Color(red: 0.055, green: 0.065, blue: 0.09),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.13))
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        }
        .buttonStyle(DeviceAppButtonStyle())
        .accessibilityLabel(title)
        .accessibilityHint("Open on this device")
        .accessibilityIdentifier("deviceWorkspace.app.\(item.id.uuidString)")
    }

    @ViewBuilder
    private var icon: some View {
        switch item.content {
        case .app(let kind):
            Image(systemName: kind.systemImage)
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.white)
        case .pwa(let installation):
            Text(installation.manifest.monogram)
                .font(.system(
                    size: installation.manifest.monogram.count > 1 ? 19 : 27,
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundStyle(.white)
        case .bookmark, .widget:
            EmptyView()
        }
    }

    private var title: String {
        switch item.content {
        case .app(let kind): kind.title
        case .pwa(let installation): installation.manifest.name
        case .bookmark(let bookmark): bookmark.title
        case .widget(let kind): kind.title
        }
    }

    private var accent: Color {
        switch item.content {
        case .app(.browser): .cyan
        case .app(.maps): .green
        case .app(.gallery): .orange
        case .app(.youtube): .red
        case .app(.remoteDesktop): .purple
        case .pwa: .blue
        case .bookmark(let bookmark):
            switch bookmark.accent {
            case .orange: .orange
            case .cyan: .cyan
            case .red: .red
            case .purple: .purple
            case .blue: .blue
            case .green: .green
            case .pink: .pink
            }
        case .widget: .orange
        }
    }
}

private struct DeviceAppButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: configuration.isPressed
            )
    }
}

private struct DeviceWorkspaceBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.055, blue: 0.085),
                    Color(red: 0.015, green: 0.02, blue: 0.035),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.cyan.opacity(0.14), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
            RadialGradient(
                colors: [.indigo.opacity(0.10), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
