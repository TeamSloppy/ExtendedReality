import SwiftUI
import UIKit

struct SpatialCanvasView: View {
    fileprivate static let coordinateSpace = "spatial.canvas"

    let environment: AppEnvironment
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DashboardStore.self) private var dashboard
    @Environment(InputRouter.self) private var inputRouter
    @Environment(HeadPoseController.self) private var headPose
    @Environment(VoiceAssistantCoordinator.self) private var voiceAssistant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voiceAssistantAnchor: VoiceAssistantPlacement.Anchor?

    var body: some View {
        GeometryReader { proxy in
            let visibleWindows = workspace.windows.filter { !$0.isMinimized }
            let presentations = workspace.presentations(
                for: visibleWindows,
                headPose: headPose.pose
            )
            ZStack {
                canvasBackground

                if workspace.presentationMode == .dashboard || visibleWindows.isEmpty {
                    SpatialDashboardView(environment: environment)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.97))
                        )
                        .zIndex(9_000)
                }

                if workspace.presentationMode == .workspace {
                    ForEach(visibleWindows) { window in
                        let layout = workspace.layout(for: window)
                        if let presentation = presentations[window.id], layout.panels.count == 1 {
                            let presentedWindow = presentation.window
                            let projectedFrame = WindowProjection.frame(
                                for: presentedWindow.transform,
                                in: CGRect(origin: .zero, size: proxy.size),
                                headPose: presentation.projectionHeadPose
                            )
                            let frame = WindowProjection.framePreservingContentAspect(
                                projectedFrame,
                                contentAspectRatio: presentedWindow.layoutContentAspectRatio,
                                verticalChrome: WindowChromeLayout.verticalChromeHeight
                            )
                            SpatialWindowChrome(
                                window: presentedWindow,
                                isFocused: workspace.activeWindowID == window.id,
                                isMoveMode: workspace.activeWindowID == window.id && workspace.controlMode == .arrange,
                                isExpanded: workspace.isExpanded(window.id),
                                canvasFrame: frame,
                                viewportSize: proxy.size,
                                rotation: .degrees(presentation.rotationDegrees),
                                environment: environment
                            )
                            .frame(width: frame.width, height: frame.height)
                            .rotationEffect(.degrees(presentation.rotationDegrees))
                            .position(x: frame.midX, y: frame.midY)
                            .zIndex(Double(window.zIndex))
                        } else if let presentation = presentations[window.id] {
                            SpatialAppGroupView(
                                window: presentation.window,
                                layout: layout,
                                viewportSize: proxy.size,
                                headPose: presentation.projectionHeadPose,
                                environment: environment
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .zIndex(Double(window.zIndex))
                        }
                    }
                }

                VStack {
                    WorkspaceStatusBar(environment: environment)
                    Spacer()
                }
                .padding(.top, max(24, proxy.safeAreaInsets.top + 12))
                .padding(.horizontal, 32)
                .zIndex(10_000)

                if workspace.presentationMode == .workspace, workspace.isAppSwitcherPresented {
                    AppSwitcherOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(15_000)
                }

                if workspace.isDockPresented, !workspace.isAppSwitcherPresented {
                    if let dockPosition = SpatialDockPlacement.position(
                        in: CGRect(origin: .zero, size: proxy.size),
                        headPose: headPose.pose,
                        isTracking: headPose.isTracking
                    ) {
                        SpatialDockView(items: dashboard.launchers)
                            .rotationEffect(.degrees(-headPose.pose.roll))
                            .position(dockPosition)
                            .zIndex(18_000)
                    } else {
                        SpatialDockView(items: dashboard.launchers)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 28)
                            .zIndex(18_000)
                    }
                }

                if voiceAssistant.state.phase.isPresented {
                    if headPose.isTracking,
                       let voiceAssistantAnchor,
                       let assistantPosition = VoiceAssistantPlacement.position(
                        for: voiceAssistantAnchor,
                        in: CGRect(origin: .zero, size: proxy.size),
                        headPose: headPose.pose,
                        isTracking: true
                    ) {
                        VoiceAssistantOverlay()
                            .frame(width: min(960, proxy.size.width * 0.72))
                            .rotationEffect(.degrees(-headPose.pose.roll))
                            .position(assistantPosition)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            .zIndex(19_000)
                    } else if !headPose.isTracking {
                        VoiceAssistantOverlay()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 64)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            .zIndex(19_000)
                    }
                }

                canvasCursor(in: proxy.size)
                    .zIndex(20_000)

                if let pair = activeSpatialPhotoPair {
                    SpatialPhotoSideBySideView(pair: pair)
                        .background(Color.black)
                        .transition(.opacity)
                        .zIndex(30_000)
                }

                if let session = activeGeneratedStereoSession {
                    GeneratedStereoFullscreenView(
                        session: session,
                        viewportSize: proxy.size
                    )
                    .transition(.opacity)
                    .zIndex(30_000)
                }
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(StatusBarHitFramePreferenceKey.self) { frames in
                inputRouter.updateStatusBarHitFrames(frames, in: proxy.size)
            }
            .onPreferenceChange(DockHitFramePreferenceKey.self) { frames in
                inputRouter.updateDockHitFrames(frames, in: proxy.size)
            }
            .onPreferenceChange(VoiceAssistantDismissHitFramePreferenceKey.self) { frame in
                inputRouter.updateVoiceAssistantDismissHitFrame(frame, in: proxy.size)
            }
            .onDisappear {
                inputRouter.clearStatusBarHitFrames()
                inputRouter.clearDockHitFrames()
                inputRouter.clearVoiceAssistantDismissHitFrame()
            }
            .onChange(of: voiceAssistant.state.phase.isPresented, initial: true) { _, isPresented in
                if isPresented, headPose.isTracking {
                    voiceAssistantAnchor = VoiceAssistantPlacement.anchor(below: headPose.pose)
                } else if !isPresented {
                    voiceAssistantAnchor = nil
                    inputRouter.clearVoiceAssistantDismissHitFrame()
                }
            }
            .onChange(of: headPose.isTracking) { _, isTracking in
                if isTracking, voiceAssistant.state.phase.isPresented {
                    voiceAssistantAnchor = VoiceAssistantPlacement.anchor(below: headPose.pose)
                } else if !isTracking {
                    voiceAssistantAnchor = nil
                }
            }
            .onChange(of: workspace.presentationMode, initial: true) { _, mode in
                inputRouter.setDashboardPresented(mode == .dashboard)
            }
            .onChange(of: workspace.isDockPresented, initial: true) { _, isPresented in
                if !isPresented {
                    inputRouter.clearDockHitFrames()
                }
            }
            .clipped()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var activeSpatialPhotoPair: SpatialPhotoStereoPair? {
        guard workspace.presentationMode == .workspace,
              !workspace.isAppSwitcherPresented,
              let window = workspace.activeWindow,
              case .gallery = window.source else { return nil }
        let session = environment.surfaces.mediaSession(for: window.id)
        guard session.presentationMode == .sourceStereo else { return nil }
        return session.spatialPhoto
    }

    private var activeGeneratedStereoSession: MediaSession? {
        guard workspace.presentationMode == .workspace,
              !workspace.isAppSwitcherPresented,
              let window = workspace.activeWindow,
              case .gallery = window.source else { return nil }
        let session = environment.surfaces.mediaSession(for: window.id)
        return session.isGeneratedStereoActive ? session : nil
    }

    private func canvasCursor(in size: CGSize) -> some View {
        let isHoveringInteractiveTarget = inputRouter.isHoveringInteractiveTarget(
            in: workspace.presentationMode == .dashboard ? nil : workspace.activeWindowID
        )
        return Circle()
            .fill(.white)
            .overlay {
                Circle().stroke(
                    isHoveringInteractiveTarget ? Color.orange : Color.black.opacity(0.6),
                    lineWidth: 2
                )
            }
            .frame(
                width: isHoveringInteractiveTarget ? 21 : 17,
                height: isHoveringInteractiveTarget ? 21 : 17
            )
            .shadow(
                color: isHoveringInteractiveTarget ? .orange.opacity(0.55) : .black.opacity(0.45),
                radius: 8
            )
            .position(
                x: inputRouter.cursor.x * size.width,
                y: inputRouter.cursor.y * size.height
            )
            .animation(.easeOut(duration: 0.12), value: isHoveringInteractiveTarget)
            .opacity(inputRouter.isCursorVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: inputRouter.isCursorVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var canvasBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.035, blue: 0.07), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            Canvas { context, size in
                let spacing: CGFloat = 64
                var path = Path()
                stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
        }
    }
}

private struct SpatialAppGroupView: View {
    let window: WorkspaceWindow
    let layout: SpatialAppLayout
    let viewportSize: CGSize
    let headPose: HeadPose
    let environment: AppEnvironment

    @Environment(WorkspaceStore.self) private var workspace

    private var projectedPanels: [ProjectedSpatialPanel] {
        SpatialWindowCompositor.project(
            window: window,
            layout: layout,
            in: CGRect(origin: .zero, size: viewportSize),
            headPose: headPose
        )
    }

    private var panelBounds: CGRect {
        SpatialWindowCompositor.boundingFrame(for: projectedPanels)
    }

    private var chromeFrame: CGRect {
        panelBounds.insetBy(dx: -18, dy: -18).insetBy(
            dx: 0,
            dy: -WindowChromeLayout.verticalChromeHeight / 2
        )
    }

    private var inputLayout: WindowChromeLayout {
        WindowChromeLayout(
            frame: chromeFrame,
            in: viewportSize,
            rotationRadians: -headPose.roll * .pi / 180,
            showsOrientation: false
        )
    }

    var body: some View {
        ZStack {
            ForEach(projectedPanels.sorted(by: panelSort)) { panel in
                SpatialPanelHostView(
                    window: window,
                    panel: panel.descriptor,
                    environment: environment
                )
                .frame(width: panel.frame.width, height: panel.frame.height)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            workspace.activePanelIDs[window.id] == panel.id ? Color.orange.opacity(0.8) : .white.opacity(0.16),
                            lineWidth: workspace.activePanelIDs[window.id] == panel.id ? 2.5 : 1
                        )
                }
                .shadow(color: .black.opacity(0.72), radius: 24, y: 12)
                .rotationEffect(.degrees(-headPose.roll))
                .position(x: panel.frame.midX, y: panel.frame.midY)
                .zIndex(Double(panel.descriptor.placement.layer))
                .accessibilityLabel(panel.descriptor.accessibilityLabel)
            }

            SpatialWindowControlBar(
                window: window,
                isFocused: workspace.activeWindowID == window.id,
                isMoveMode: workspace.activeWindowID == window.id && workspace.controlMode == .arrange,
                isExpanded: workspace.isExpanded(window.id),
                showsOrientation: false,
                environment: environment
            )
            .frame(width: min(max(panelBounds.width * 0.48, 240), 680), height: WindowChromeLayout.controlBarHeight)
            .rotationEffect(.degrees(-headPose.roll))
            .position(x: panelBounds.midX, y: panelBounds.minY - 58)
            .zIndex(100)

            SpatialWindowResizeHandle(
                isFocused: workspace.activeWindowID == window.id,
                curvature: 0
            )
            .rotationEffect(.degrees(-headPose.roll))
            .position(x: panelBounds.maxX + 22, y: panelBounds.midY)
            .zIndex(100)

            SpatialWindowMoveHandle(
                window: window,
                windowID: window.id,
                isMoveMode: workspace.activeWindowID == window.id && workspace.controlMode == .arrange,
                environment: environment
            )
            .rotationEffect(.degrees(-headPose.roll))
            .position(x: panelBounds.midX, y: panelBounds.maxY + 34)
            .zIndex(100)
        }
        .onAppear(perform: registerLayout)
        .onChange(of: inputLayout) { _, _ in registerLayout() }
        .onChange(of: window.zIndex) { _, _ in registerLayout() }
        .onDisappear {
            environment.inputRouter.removeWindowLayout(for: window.id)
            environment.inputRouter.removePanelLayouts(for: window.id)
        }
    }

    private func registerLayout() {
        environment.inputRouter.updateWindowLayout(inputLayout, for: window.id, zIndex: window.zIndex)
        environment.inputRouter.updatePanelLayouts(
            projectedPanels.map {
                SpatialPanelInputLayout(
                    windowID: window.id,
                    panelID: $0.id,
                    frame: $0.frame,
                    canvasSize: viewportSize,
                    appZIndex: window.zIndex,
                    layer: $0.descriptor.placement.layer,
                    depth: $0.transform.virtualDistance,
                    rotationRadians: -headPose.roll * .pi / 180
                )
            }
        )
    }

    private func panelSort(_ lhs: ProjectedSpatialPanel, _ rhs: ProjectedSpatialPanel) -> Bool {
        if lhs.descriptor.placement.layer != rhs.descriptor.placement.layer {
            return lhs.descriptor.placement.layer < rhs.descriptor.placement.layer
        }
        return lhs.transform.virtualDistance > rhs.transform.virtualDistance
    }
}

private struct SpatialPanelHostView: View {
    let window: WorkspaceWindow
    let panel: SpatialPanelDescriptor
    let environment: AppEnvironment

    var body: some View {
        switch panel.content {
        case .primary:
            SurfaceHostView(window: window, environment: environment)
        case .native(let key):
            YouTubeSpatialPanelView(
                key: key,
                session: environment.surfaces.youtubeSession(for: window.id),
                apiClient: environment.youtubeAPI
            )
        case .web(let url):
            if case .pwa(let installation, _) = window.source {
                PWAWebPanelView(
                    session: environment.surfaces.pwaPanel(
                        for: window.id,
                        panelID: panel.id,
                        installation: installation,
                        initialURL: url
                    )
                )
            } else {
                ContentUnavailableView("Unavailable panel", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

private struct PWAWebPanelView: View {
    @Bindable var session: BrowserSession

    var body: some View {
        ZStack {
            BrowserSurfaceView(session: session)
            if let error = session.lastErrorMessage {
                ContentUnavailableView {
                    Label("Panel unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") { session.reload() }
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }
}

private struct SpatialDockView: View {
    let items: [DashboardItem]

    @Environment(InputRouter.self) private var inputRouter

    var body: some View {
        HStack(spacing: 10) {
            dockBackButton
                .dockHitTarget(.dismiss, in: SpatialCanvasView.coordinateSpace)

            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1, height: 54)

            ForEach(items) { item in
                dockItem(item)
                    .dockHitTarget(.launch(item.id), in: SpatialCanvasView.coordinateSpace)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.2), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.58), radius: 26, y: 12)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application dock")
    }

    private var dockBackButton: some View {
        let isHovered = inputRouter.dockAction() == .dismiss
        return VStack(spacing: 5) {
            Image(systemName: "arrow.backward")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(isHovered ? .orange : .white.opacity(0.88))
                .frame(width: 58, height: 54)
                .background(
                    isHovered ? Color.white.opacity(0.16) : Color.black.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(isHovered ? Color.orange : .clear, lineWidth: 2.5)
                }

            Text("Back")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 66)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.12 : 1)
        .offset(y: isHovered ? -5 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Back to windows")
    }

    private func dockItem(_ item: DashboardItem) -> some View {
        let action = DockAction.launch(item.id)
        let isHovered = inputRouter.dockAction() == action

        return VStack(spacing: 5) {
            dockIcon(for: item)
                .frame(width: 58, height: 54)
                .background(
                    isHovered ? Color.white.opacity(0.16) : Color.black.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(
                            isHovered ? accent(for: item) : .clear,
                            lineWidth: isHovered ? 2.5 : 1
                        )
                }

            Text(title(for: item))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(width: 66)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.12 : 1)
        .offset(y: isHovered ? -5 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: item))
        .accessibilityHint("Opens in a new window")
    }

    @ViewBuilder
    private func dockIcon(for item: DashboardItem) -> some View {
        switch item.content {
        case .app(let kind):
            Image(systemName: kind.systemImage)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(accent(for: item))
        case .pwa(let installation):
            monogram(installation.manifest.monogram, accent: accent(for: item))
        case .bookmark(let bookmark):
            monogram(bookmark.monogram, accent: accent(for: item))
        case .widget:
            EmptyView()
        }
    }

    private func monogram(_ value: String, accent: Color) -> some View {
        Text(value)
            .font(.system(size: value.count > 1 ? 18 : 25, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(accent.opacity(0.78), in: Circle())
    }

    private func title(for item: DashboardItem) -> String {
        switch item.content {
        case .app(let kind): kind.title
        case .pwa(let installation): installation.manifest.name
        case .bookmark(let bookmark): bookmark.title
        case .widget(let kind): kind.title
        }
    }

    private func accent(for item: DashboardItem) -> Color {
        switch item.content {
        case .app(.gallery): .orange
        case .app(.browser): .cyan
        case .app(.maps): .green
        case .app(.youtube): .red
        case .app(.remoteDesktop): .purple
        case .pwa: .blue
        case .bookmark(let bookmark): color(for: bookmark.accent)
        case .widget: .orange
        }
    }

    private func color(for accent: DashboardAccent) -> Color {
        switch accent {
        case .orange: .orange
        case .cyan: .cyan
        case .red: .red
        case .purple: .purple
        case .blue: .blue
        case .green: .green
        case .pink: .pink
        }
    }
}

private struct DockHitFramePreferenceKey: PreferenceKey {
    static let defaultValue: [DockAction: CGRect] = [:]

    static func reduce(value: inout [DockAction: CGRect], nextValue: () -> [DockAction: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func dockHitTarget(_ action: DockAction, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DockHitFramePreferenceKey.self,
                    value: [action: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }
}

private struct VoiceAssistantOverlay: View {
    @Environment(VoiceAssistantCoordinator.self) private var assistant
    @Environment(VoiceAssistantSettings.self) private var settings

    var body: some View {
        VStack(spacing: 18) {
            if !assistant.state.responseText.isEmpty || !assistant.state.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !assistant.state.transcript.isEmpty {
                        Text(assistant.state.transcript)
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(2)
                    }
                    if !assistant.state.responseText.isEmpty {
                        Text(assistant.state.responseText)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 940, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
            }

            HStack(spacing: 18) {
                SloppieAvatarView(
                    pet: assistant.state.pet,
                    phase: assistant.state.phase,
                    dashboardURL: settings.snapshot?.dashboardURL
                )
                .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 4) {
                    Text(assistant.state.agentName)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(assistant.state.statusText)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }
                .frame(maxWidth: 420, alignment: .leading)

                Button {
                    assistant.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.12), in: Circle())
                .voiceAssistantDismissHitTarget(in: SpatialCanvasView.coordinateSpace)
                .accessibilityLabel("Turn off Voice Mode")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(accent.opacity(0.62), lineWidth: 2) }
            .shadow(color: accent.opacity(0.34), radius: 28)
        }
        .animation(.easeInOut(duration: 0.22), value: assistant.state.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(assistant.state.agentName), \(assistant.state.statusText)")
    }

    private var accent: Color {
        switch assistant.state.phase {
        case .listening: .cyan
        case .transcribing, .awaitingAgent: .orange
        case .preview: .purple
        case .speaking: .green
        case .error: .red
        default: .white
        }
    }
}

private struct VoiceAssistantDismissHitFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private extension View {
    func voiceAssistantDismissHitTarget(in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VoiceAssistantDismissHitFramePreferenceKey.self,
                    value: proxy.frame(in: .named(coordinateSpace))
                )
            }
        }
    }
}

private struct SloppieAvatarView: View {
    let pet: SloppyAgentPet?
    let phase: VoiceAssistantPhase
    let dashboardURL: URL?

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.38), Color.black.opacity(0.9)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 62
                    )
                )
                .overlay { Circle().strokeBorder(accent.opacity(0.8), lineWidth: 2) }
                .shadow(color: accent.opacity(0.72), radius: phase == .listening ? 24 : 14)

            if let frameDescriptor {
                TimelineView(.animation(minimumInterval: frameDescriptor.interval)) { timeline in
                    SloppieSpriteFrame(
                        url: frameDescriptor.url,
                        frame: frameDescriptor.frame(at: timeline.date)
                    )
                    .padding(12)
                }
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white, accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .listening || phase == .speaking)
            }
        }
        .scaleEffect(phase == .listening ? 1.06 : 1)
    }

    private var accent: Color {
        switch phase {
        case .listening: .cyan
        case .transcribing, .awaitingAgent: .orange
        case .speaking: .green
        case .error: .red
        default: .purple
        }
    }

    private var frameDescriptor: SloppieFrameDescriptor? {
        guard let dashboardURL else { return nil }
        let stateKey: String = switch phase {
        case .listening, .preview: "interacted"
        case .transcribing, .awaitingAgent: "walk"
        case .speaking: "happy"
        case .error: "sad"
        default: "idle"
        }
        let currentStage = pet?.visual?.currentStage ?? 1
        let asset = pet?.stageAssets.first(where: { $0.stage == currentStage })
        let path = asset?.spriteSheetPath ?? "/pets/presets/spark-fox/1.png"
        let fallbackRange = SloppyAgentPet.FrameRange(start: 0, end: 3, fps: 6, loop: true)
        let range = asset?.stateFrameRanges[stateKey] ?? fallbackRange
        guard let url = URL(string: path, relativeTo: dashboardURL)?.absoluteURL else { return nil }
        return SloppieFrameDescriptor(url: url, range: range)
    }
}

private struct SloppieFrameDescriptor {
    let url: URL
    let range: SloppyAgentPet.FrameRange

    var interval: TimeInterval { 1 / max(range.fps, 1) }

    func frame(at date: Date) -> Int {
        let count = max(range.end - range.start + 1, 1)
        guard range.fps > 0 else { return range.start }
        let tick = Int(date.timeIntervalSinceReferenceDate * range.fps)
        return range.start + abs(tick % count)
    }
}

private struct SloppieSpriteFrame: View {
    let url: URL
    let frame: Int

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    spriteFrame(image, size: proxy.size)
                case .empty:
                    ProgressView()
                        .tint(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    if let image = BundledSparkFox.image {
                        spriteFrame(Image(uiImage: image), size: proxy.size)
                    } else {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 42, weight: .bold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                @unknown default:
                    EmptyView()
                }
            }
        }
        .clipped()
    }

    private func spriteFrame(_ image: Image, size: CGSize) -> some View {
        image
            .resizable()
            .interpolation(.none)
            .frame(width: size.width * 4, height: size.height * 6)
            .offset(
                x: -CGFloat(frame % 4) * size.width,
                y: -CGFloat(frame / 4) * size.height
            )
    }
}

private struct AppSwitcherOverlay: View {
    private static let coordinateSpace = "spatial.app-switcher"

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(InputRouter.self) private var inputRouter

    var body: some View {
        GeometryReader { proxy in
            let windows = workspace.windows.sorted(by: { $0.zIndex > $1.zIndex })
            let columnCount = Self.columnCount(for: windows.count)
            let rowCount = max(1, Int(ceil(Double(windows.count) / Double(columnCount))))
            let cardHeight = Self.cardHeight(rowCount: rowCount, canvasHeight: proxy.size.height)

            ZStack {
                Color.black.opacity(0.78)

                VStack(spacing: 28) {
                    VStack(spacing: 7) {
                        Label("Open apps", systemImage: "square.stack.3d.up.fill")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Point at an app and click to bring it to the center")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }

                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 20),
                            count: columnCount
                        ),
                        spacing: 20
                    ) {
                        ForEach(windows) { window in
                            appCard(window, height: cardHeight)
                                .appSwitcherHitTarget(window.id, in: Self.coordinateSpace)
                        }
                    }
                }
                .padding(34)
                .frame(width: min(proxy.size.width * 0.84, 1_420))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.65), radius: 44, y: 18)
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(AppSwitcherHitFramePreferenceKey.self) { frames in
                inputRouter.updateAppSwitcherHitFrames(frames, in: proxy.size)
            }
            .onAppear {
                inputRouter.setAppSwitcherPresented(true)
            }
            .onDisappear {
                inputRouter.clearAppSwitcherHitFrames()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func appCard(_ window: WorkspaceWindow, height: CGFloat) -> some View {
        let isHovered = inputRouter.appSwitcherItem() == window.id
        let isActive = workspace.activeWindowID == window.id
        let accent = isHovered ? Color.orange : isActive ? Color.cyan : Color.white.opacity(0.16)

        return VStack(spacing: 13) {
            Image(systemName: window.systemImage)
                .font(.system(size: min(48, height * 0.3), weight: .semibold))
                .foregroundStyle(isHovered ? .orange : isActive ? .cyan : .white.opacity(0.86))

            Text(window.title)
                .font(.system(size: min(22, height * 0.15), weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if isActive {
                Text("ACTIVE")
                    .foregroundStyle(.cyan)
                    .appSwitcherStatusBadge()
            } else if window.isMinimized {
                Text("MINIMIZED")
                    .foregroundStyle(.white.opacity(0.52))
                    .appSwitcherStatusBadge()
            } else {
                Text("OPEN")
                    .foregroundStyle(.white.opacity(0.52))
                    .appSwitcherStatusBadge()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            isHovered ? Color.orange.opacity(0.15) : Color.black.opacity(0.28),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(accent, lineWidth: isHovered || isActive ? 3 : 1)
        }
        .scaleEffect(isHovered ? 1.035 : 1)
        .shadow(color: isHovered ? .orange.opacity(0.3) : .clear, radius: 18)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.title)
        .accessibilityValue(isActive ? "Active" : window.isMinimized ? "Minimized" : "Open")
    }

    private static func columnCount(for itemCount: Int) -> Int {
        guard itemCount > 4 else { return max(itemCount, 1) }
        return max(1, Int(ceil(sqrt(Double(itemCount) * 16 / 9))))
    }

    private static func cardHeight(rowCount: Int, canvasHeight: CGFloat) -> CGFloat {
        let availableHeight = max(canvasHeight * 0.58 - 100, 100)
        let totalSpacing = CGFloat(max(rowCount - 1, 0)) * 20
        return min(190, max(78, (availableHeight - totalSpacing) / CGFloat(rowCount)))
    }
}

private struct AppSwitcherHitFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func appSwitcherHitTarget(_ id: UUID, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AppSwitcherHitFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }

    func appSwitcherStatusBadge() -> some View {
        font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.2)
    }
}

private struct WorkspaceStatusBar: View {
    let environment: AppEnvironment
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(InputRouter.self) private var inputRouter
    @Environment(HeadPoseController.self) private var headPose
    @State private var batteryLevel: Int?
    @State private var batteryState: UIDevice.BatteryState = .unknown

    var body: some View {
        HStack(spacing: 0) {
            Label("Work", systemImage: "square.grid.2x2.fill")
                .foregroundStyle(.orange)
                .statusBarSection()

            if environment.wakeWordController.state.isListening {
                divider

                Label("Listening for Sloppy", systemImage: "waveform.badge.mic")
                    .foregroundStyle(.green)
                    .statusBarSection()
            }

            divider

            PeriodicDateView(every: .seconds(30)) { date in
                Text(date, format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
            }
            .statusBarSection(minWidth: 104)

            divider

            deviceState
                .statusBarSection()

            divider

            controls
                .statusBarSection(horizontalPadding: 10)
        }
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .frame(height: 66)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.11), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear(perform: startBatteryMonitoring)
        .onDisappear {
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            refreshBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            refreshBatteryState()
        }
    }

    private var deviceState: some View {
        HStack(spacing: 18) {
            headTrackingState

            Image(systemName: workspace.isExternalDisplayConnected ? "wifi" : "wifi.slash")
                .foregroundStyle(workspace.isExternalDisplayConnected ? .white.opacity(0.72) : .orange)
                .accessibilityLabel("External display")
                .accessibilityValue(workspace.isExternalDisplayConnected ? "Connected" : "Disconnected")

            HStack(spacing: 8) {
                Image(systemName: batterySymbol)
                Text(batteryText)
                    .monospacedDigit()
            }
            .foregroundStyle(batteryColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("iPhone battery")
            .accessibilityValue(batteryAccessibilityValue)
        }
    }

    private var headTrackingState: some View {
        HStack(spacing: 8) {
            Image(systemName: "eyeglasses")

            VStack(alignment: .leading, spacing: 1) {
                Text("3DoF")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1)

                Text(headPose.isTracking ? "TRACKING" : "NOT TRACKING")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(headTrackingColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("3DoF head tracking")
        .accessibilityValue(headPose.statusText)
    }

    private var headTrackingColor: Color {
        switch headPose.availability {
        case .available:
            .cyan
        case .waiting:
            .orange
        case .unavailable:
            .red
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button {
                environment.showDashboard()
            } label: {
                Image(systemName: "house.fill")
            }
            .statusBarButton(isSelected: workspace.presentationMode == .dashboard)
            .statusBarHitTarget(.dashboard, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Dashboard")

            Button {
                workspace.controlMode = .pointer
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .statusBarButton(isSelected: workspace.controlMode == .pointer)
            .statusBarHitTarget(.pointerMode, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Cursor mode")

            Button {
                workspace.controlMode = .arrange
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .statusBarButton(isSelected: workspace.controlMode == .arrange)
            .statusBarHitTarget(.arrangeMode, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Arrange mode")

            Button {
                workspace.toggleLayoutMode(for: headPose.pose)
            } label: {
                Image(systemName: workspace.layoutMode.systemImage)
            }
            .statusBarButton(isSelected: workspace.layoutMode == .stack)
            .statusBarHitTarget(.toggleWorkspaceLayout, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Workspace layout")
            .accessibilityValue(workspace.layoutMode.title)

            Button {
                workspace.recenter()
                inputRouter.resetCursor()
                headPose.recenter()
            } label: {
                Image(systemName: "scope")
            }
            .statusBarButton()
            .statusBarHitTarget(.recenter, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Recenter workspace")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 26)
    }

    private var batteryText: String {
        batteryLevel.map { "\($0)%" } ?? "—"
    }

    private var batterySymbol: String {
        guard let batteryLevel else { return "battery.0percent" }
        switch batteryLevel {
        case 76 ... 100: return "battery.100percent"
        case 51 ... 75: return "battery.75percent"
        case 26 ... 50: return "battery.50percent"
        case 1 ... 25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryColor: Color {
        if batteryState == .charging || batteryState == .full {
            return .green
        }
        if let batteryLevel, batteryLevel <= 20 {
            return .red
        }
        return .white.opacity(0.9)
    }

    private var batteryAccessibilityValue: String {
        let charge = batteryLevel.map { "\($0) percent" } ?? "unavailable"
        return batteryState == .charging ? "\(charge), charging" : charge
    }

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBatteryState()
    }

    private func refreshBatteryState() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level < 0 ? nil : Int((level * 100).rounded())
        batteryState = UIDevice.current.batteryState
    }
}

private extension View {
    func statusBarSection(
        minWidth: CGFloat? = nil,
        horizontalPadding: CGFloat = 20
    ) -> some View {
        frame(minWidth: minWidth)
            .padding(.horizontal, horizontalPadding)
    }

    func statusBarButton(isSelected: Bool = false) -> some View {
        buttonStyle(StatusBarButtonStyle(isSelected: isSelected))
    }

    func statusBarHitTarget(_ action: StatusBarAction, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: StatusBarHitFramePreferenceKey.self,
                    value: [action: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }
}

private struct StatusBarHitFramePreferenceKey: PreferenceKey {
    static let defaultValue: [StatusBarAction: CGRect] = [:]

    static func reduce(
        value: inout [StatusBarAction: CGRect],
        nextValue: () -> [StatusBarAction: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct StatusBarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(isSelected ? Color.orange : Color.white.opacity(0.58))
            .frame(width: 48, height: 46)
            .background(
                isSelected ? Color.orange.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SpatialWindowChrome: View {
    let window: WorkspaceWindow
    let isFocused: Bool
    let isMoveMode: Bool
    let isExpanded: Bool
    let canvasFrame: CGRect
    let viewportSize: CGSize
    let rotation: Angle
    let environment: AppEnvironment

    private var inputLayout: WindowChromeLayout {
        WindowChromeLayout(
            frame: canvasFrame,
            in: viewportSize,
            rotationRadians: rotation.radians
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let curvature = WindowProjection.curvatureAmount(for: window.transform)
            let cornerRadius = min(
                110,
                26 + curvature * min(proxy.size.height * 0.14, 84)
            )
            let surfaceShape = RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )

            VStack(spacing: 0) {
                SpatialWindowControlBar(
                    window: window,
                    isFocused: isFocused,
                    isMoveMode: isMoveMode,
                    isExpanded: isExpanded,
                    environment: environment
                )
                .frame(
                    width: min(max(proxy.size.width * 0.84, 240), 680),
                    height: WindowChromeLayout.controlBarHeight
                )

                Spacer()
                    .frame(height: WindowChromeLayout.controlBarGap)

                SurfaceHostView(window: window, environment: environment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(surfaceShape)
                    .overlay {
                        SpatialWindowCurvatureOverlay(amount: curvature)
                            .clipShape(surfaceShape)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        surfaceShape
                            .strokeBorder(
                                isMoveMode ? Color.purple.opacity(0.9) : Color.white.opacity(isFocused ? 0.22 : 0.12),
                                lineWidth: isMoveMode ? 2.5 : 1
                            )
                    }
                    .overlay(alignment: .trailing) {
                        SpatialWindowResizeHandle(
                            isFocused: isFocused,
                            curvature: curvature
                        )
                        .padding(.trailing, 6)
                    }
                    .shadow(
                        color: isMoveMode ? Color.purple.opacity(0.72) : Color.black.opacity(0.7),
                        radius: isMoveMode ? 32 : 24,
                        y: isMoveMode ? 0 : 12
                    )

                Spacer()
                    .frame(height: WindowChromeLayout.handleGap)

                SpatialWindowMoveHandle(
                    window: window,
                    windowID: window.id,
                    isMoveMode: isMoveMode,
                    environment: environment
                )
                .frame(height: WindowChromeLayout.handleHeight)
            }
            .onAppear {
                environment.inputRouter.updateWindowLayout(
                    inputLayout,
                    for: window.id,
                    zIndex: window.zIndex
                )
            }
            .onChange(of: inputLayout) { _, layout in
                environment.inputRouter.updateWindowLayout(
                    layout,
                    for: window.id,
                    zIndex: window.zIndex
                )
            }
            .onChange(of: window.zIndex) { _, zIndex in
                environment.inputRouter.updateWindowLayout(
                    inputLayout,
                    for: window.id,
                    zIndex: zIndex
                )
            }
        }
        .onDisappear {
            environment.inputRouter.removeWindowLayout(for: window.id)
        }
    }
}

private struct SpatialWindowCurvatureOverlay: View {
    let amount: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let edgeWidth = max(48, proxy.size.width * 0.16)
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.42 * Double(amount)), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.42 * Double(amount))],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)
            }
        }
        .opacity(amount)
    }
}

private struct SpatialWindowResizeHandle: View {
    let isFocused: Bool
    let curvature: CGFloat

    var body: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule()
                    .strokeBorder(
                        isFocused ? Color.orange.opacity(0.9) : Color.white.opacity(0.36),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isFocused ? Color.orange : Color.white.opacity(0.72))
            }
            .frame(width: 20, height: 112)
            .shadow(
                color: isFocused ? Color.orange.opacity(0.34) : Color.black.opacity(0.42),
                radius: 12 + curvature * 8
            )
            .accessibilityElement()
            .accessibilityLabel("Resize window")
            .accessibilityHint("Drag horizontally to resize")
    }
}

private struct SpatialWindowControlBar: View {
    let window: WorkspaceWindow
    let isFocused: Bool
    let isMoveMode: Bool
    let isExpanded: Bool
    var showsOrientation = true
    let environment: AppEnvironment

    var body: some View {
        HStack(spacing: 0) {
            if showsOrientation {
                controlButton(
                    title: window.effectiveLayoutOrientation == .horizontal
                        ? "Switch to vertical layout"
                        : "Switch to horizontal layout",
                    systemImage: "rectangle.portrait.rotate"
                ) {
                    environment.workspace.toggleLayoutOrientation(window.id)
                }
            }

            let stackForcesAnchor = environment.workspace.layoutMode == .stack
            controlButton(
                title: stackForcesAnchor
                    ? "Stack temporarily uses Anchor"
                    : "Switch to \(window.attachmentMode.next.title)",
                systemImage: stackForcesAnchor ? "pin.fill" : window.attachmentMode.systemImage,
                isDisabled: stackForcesAnchor
            ) {
                environment.workspace.toggleAttachmentMode(
                    for: window.id,
                    headPose: environment.headPose.pose
                )
            }

            controlButton(title: "Minimize", systemImage: "chevron.down") {
                environment.minimizeWindow(window.id)
            }

            controlButton(
                title: isExpanded ? "Restore window" : "Expand window",
                systemImage: isExpanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            ) {
                environment.workspace.toggleExpanded(window.id, for: environment.headPose.pose)
            }

            controlButton(title: "Close", systemImage: "xmark") {
                environment.closeWindow(window.id)
            }
        }
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isMoveMode ? Color.purple.opacity(0.78) : Color.white.opacity(isFocused ? 0.2 : 0.12),
                    lineWidth: isMoveMode ? 2 : 1
                )
        }
        .shadow(
            color: isMoveMode ? Color.purple.opacity(0.54) : Color.black.opacity(0.42),
            radius: isMoveMode ? 24 : 14,
            y: isMoveMode ? 0 : 8
        )
    }

    private func controlButton(
        title: String,
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white.opacity(isFocused ? 0.96 : 0.66))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.42 : 1)
    }
}

private struct SpatialWindowMoveHandle: View {
    let window: WorkspaceWindow
    let windowID: UUID
    let isMoveMode: Bool
    let environment: AppEnvironment

    var body: some View {
        ZStack {
            Capsule()
                .fill(isMoveMode ? Color.purple.opacity(0.82) : Color.white.opacity(0.72))
                .frame(width: 112, height: 6)
                .shadow(
                    color: isMoveMode ? Color.purple.opacity(0.9) : Color.black.opacity(0.28),
                    radius: isMoveMode ? 14 : 3
                )

            if isMoveMode {
                HStack(spacing: 8) {
                    if let position = environment.workspace.stackPosition(for: windowID) {
                        Text("#\(position.index + 1)/\(position.count)")
                    }
                    Text("\(window.transform.virtualDistance, specifier: "%.2f") m")
                }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.purple.opacity(0.66), lineWidth: 1)
                    }
                    .offset(x: 108)
            }
        }
        .frame(width: 180, height: WindowChromeLayout.handleHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            environment.workspace.focus(windowID)
            environment.workspace.controlMode = .arrange
        }
        .accessibilityElement()
        .accessibilityLabel("Move window")
        .accessibilityValue(isMoveMode ? "Move mode active, distance \(window.transform.virtualDistance) meters" : "Move mode inactive")
        .accessibilityHint("Double tap to enter move mode")
    }
}

#if DEBUG
#Preview("External Display — Dashboard") {
    let environment = AppEnvironment.preview(windowCount: 0, showsDashboard: true)
    SpatialCanvasView(environment: environment)
        .previewEnvironment(environment)
        .frame(width: 1_920, height: 1_080)
}

#Preview("External Display — Window") {
    let environment = AppEnvironment.preview()
    SpatialCanvasView(environment: environment)
        .previewEnvironment(environment)
        .frame(width: 1_920, height: 1_080)
}

#Preview("External Display — App Switcher") {
    let environment = AppEnvironment.preview(windowCount: 4, showsAppSwitcher: true)
    SpatialCanvasView(environment: environment)
        .previewEnvironment(environment)
        .frame(width: 1_920, height: 1_080)
}
#endif
