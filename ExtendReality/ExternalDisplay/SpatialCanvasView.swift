import SwiftUI
import UIKit

enum SpatialChromeVisibility {
    static let edgeRevealFraction = 0.1

    static func showsStatusBar(
        isTracking: Bool,
        cursor: CGPoint
    ) -> Bool {
        isTracking || cursor.y <= edgeRevealFraction
    }

    static func showsDock(
        isTracking: Bool,
        cursor: CGPoint
    ) -> Bool {
        isTracking || cursor.y >= 1 - edgeRevealFraction
    }
}

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
            let showsStatusBar =
                SpatialChromeVisibility.showsStatusBar(
                    isTracking: headPose.isTracking,
                    cursor: inputRouter.cursor
                )
                || dashboard.isScenarioPickerPresented
                || dashboard.isWidgetPickerPresented
            let showsDock = SpatialChromeVisibility.showsDock(
                isTracking: headPose.isTracking,
                cursor: inputRouter.cursor
            )
            ZStack {
                canvasBackground

                if workspace.presentationMode == .widgets {
                    SpatialDashboardView(
                        environment: environment,
                        mode: .widgets,
                        isInteractive: !workspace.isDashboardPresented
                    )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.97))
                        )
                        .zIndex(9_000)
                }

                if workspace.presentationMode == .windows {
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

                if showsStatusBar {
                    VStack {
                        WorkspaceStatusBar(environment: environment)
                        Spacer()
                    }
                    .padding(.top, max(24, proxy.safeAreaInsets.top + 12))
                    .padding(.horizontal, 32)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .zIndex(10_000)
                }

                if showsStatusBar, dashboard.isScenarioPickerPresented {
                    VStack {
                        ScenarioPickerOverlay()
                            .padding(.top, max(104, proxy.safeAreaInsets.top + 92))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(11_000)
                }

                if showsStatusBar,
                   workspace.presentationMode == .widgets,
                   !workspace.isDashboardPresented,
                   dashboard.isWidgetPickerPresented {
                    VStack {
                        WidgetPickerOverlay()
                            .padding(.top, max(104, proxy.safeAreaInsets.top + 92))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(11_000)
                }

                if workspace.presentationMode == .windows, workspace.isAppSwitcherPresented {
                    AppSwitcherOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(15_000)
                }

                if workspace.isDashboardPresented {
                    SpatialDashboardView(
                        environment: environment,
                        mode: .dashboard,
                        isInteractive: true
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.97))
                    )
                    .zIndex(16_000)
                }

                if showsDock {
                    Group {
                        if let dockPosition = SpatialDockPlacement.position(
                            in: CGRect(origin: .zero, size: proxy.size),
                            headPose: headPose.pose,
                            isTracking: headPose.isTracking
                        ) {
                            SpatialDockView(windows: workspace.windows)
                                .rotationEffect(.degrees(-headPose.pose.roll))
                                .position(dockPosition)
                        } else {
                            SpatialDockView(windows: workspace.windows)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, 28)
                        }
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    .zIndex(48_000)
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
                            .zIndex(45_000)
                    } else if !headPose.isTracking {
                        VoiceAssistantOverlay()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 64)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            .zIndex(45_000)
                    }
                }

                if environment.watchRemote.isPointerActive,
                   environment.watchRemote.showsPointerGuide,
                   inputRouter.isCursorVisible {
                    WatchPointerGuide(
                        cursor: inputRouter.cursor,
                        wristLocation: environment.watchRemote.pointerWristLocation
                    )
                    .zIndex(49_000)
                }

                canvasCursor(in: proxy.size)
                    .zIndex(50_000)

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
                    dashboard.dismissWidgetPicker()
                    dashboard.dismissScenarioPicker()
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: showsStatusBar
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: showsDock
            )
            .onChange(of: workspace.presentationMode, initial: true) { _, mode in
                inputRouter.setDashboardPresented(
                    workspace.isDashboardPresented || mode == .widgets
                )
            }
            .onChange(of: workspace.isDashboardPresented, initial: true) { _, isPresented in
                inputRouter.setDashboardPresented(
                    isPresented || workspace.presentationMode == .widgets
                )
            }
            .clipped()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var activeSpatialPhotoPair: SpatialPhotoStereoPair? {
        guard workspace.presentationMode == .windows,
              !workspace.isAppSwitcherPresented,
              let window = workspace.activeWindow,
              case .gallery = window.source else { return nil }
        let session = environment.surfaces.mediaSession(for: window.id)
        guard session.presentationMode == .sourceStereo else { return nil }
        return session.spatialPhoto
    }

    private var activeGeneratedStereoSession: MediaSession? {
        guard workspace.presentationMode == .windows,
              !workspace.isAppSwitcherPresented,
              let window = workspace.activeWindow else { return nil }
        let session: MediaSession
        switch window.source {
        case .gallery:
            session = environment.surfaces.mediaSession(for: window.id)
        case .youtube:
            session = environment.surfaces.youtubeSession(for: window.id).generatedStereoSession
        default:
            return nil
        }
        return session.isGeneratedStereoActive ? session : nil
    }

    private func canvasCursor(in size: CGSize) -> some View {
        let isHoveringInteractiveTarget = inputRouter.isHoveringInteractiveTarget(
            in: workspace.isDashboardPresented || workspace.presentationMode == .widgets
                ? nil
                : workspace.activeWindowID
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

private struct WatchPointerGuide: View {
    let cursor: CGPoint
    let wristLocation: WatchWristLocation

    var body: some View {
        GeometryReader { proxy in
            let inset = min(max(proxy.size.width * 0.075, 54), 144)
            let origin = CGPoint(
                x: wristLocation == .left ? inset : proxy.size.width - inset,
                y: proxy.size.height * 0.84
            )
            let target = CGPoint(
                x: cursor.x * proxy.size.width,
                y: cursor.y * proxy.size.height
            )

            ZStack {
                Canvas { context, _ in
                    var beam = Path()
                    beam.move(to: origin)
                    beam.addLine(to: target)
                    context.stroke(
                        beam,
                        with: .color(.cyan.opacity(0.16)),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    context.stroke(
                        beam,
                        with: .linearGradient(
                            Gradient(colors: [.cyan.opacity(0.9), .cyan.opacity(0.28)]),
                            startPoint: origin,
                            endPoint: target
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                }

                Image(systemName: "applewatch")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().stroke(.cyan.opacity(0.82), lineWidth: 2)
                    }
                    .shadow(color: .cyan.opacity(0.42), radius: 10)
                    .position(origin)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

            SpatialWindowResizeOverlay(
                windowID: window.id,
                isFocused: workspace.activeWindowID == window.id,
                curvature: 0
            )
            .frame(width: panelBounds.width, height: panelBounds.height)
            .rotationEffect(.degrees(-headPose.roll))
            .position(x: panelBounds.midX, y: panelBounds.midY)
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
                session: environment.surfaces.youtubeSession(for: window.id)
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
    let windows: [WorkspaceWindow]

    @Environment(InputRouter.self) private var inputRouter

    var body: some View {
        HStack(spacing: 10) {
            if windows.isEmpty {
                Label("No open windows", systemImage: "square.stack.3d.down.right")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 14)
                    .frame(height: 62)
            } else {
                ForEach(windows.sorted(by: { $0.zIndex > $1.zIndex })) { window in
                    dockItem(window)
                        .dockHitTarget(.focus(window.id), in: SpatialCanvasView.coordinateSpace)
                }
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

    private func dockItem(_ window: WorkspaceWindow) -> some View {
        let action = DockAction.focus(window.id)
        let isHovered = inputRouter.dockAction() == action

        return VStack(spacing: 5) {
            dockIcon(for: window)
                .frame(width: 58, height: 54)
                .background(
                    isHovered ? Color.white.opacity(0.16) : Color.black.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(
                            isHovered ? accent(for: window) : .clear,
                            lineWidth: isHovered ? 2.5 : 1
                        )
                }

            Text(window.title)
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
        .accessibilityLabel(window.title)
        .accessibilityHint(window.isMinimized ? "Restores this window" : "Focuses this window")
    }

    @ViewBuilder
    private func dockIcon(for window: WorkspaceWindow) -> some View {
        switch window.source {
        case .pwa(let installation, _):
            monogram(installation.manifest.monogram, accent: accent(for: window))
        default:
            Image(systemName: window.systemImage)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(accent(for: window))
        }
    }

    private func monogram(_ value: String, accent: Color) -> some View {
        Text(value)
            .font(.system(size: value.count > 1 ? 18 : 25, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(accent.opacity(0.78), in: Circle())
    }

    private func accent(for window: WorkspaceWindow) -> Color {
        switch window.source {
        case .gallery: .orange
        case .browser: .cyan
        case .maps: .green
        case .youtube: .red
        case .remoteDesktop, .macCapture: .purple
        case .pwa: .blue
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let windows = workspace.windows.sorted(by: { $0.zIndex > $1.zIndex })
            let columnCount = Self.columnCount(for: windows.count)
            let rowCount = max(1, Int(ceil(Double(windows.count) / Double(columnCount))))
            let cardHeight = Self.cardHeight(rowCount: rowCount, canvasHeight: proxy.size.height)

            ZStack {
                Color.black.opacity(0.86)

                RadialGradient(
                    colors: [Color.cyan.opacity(0.1), .clear],
                    center: UnitPoint(x: 0.72, y: 0.36),
                    startRadius: 20,
                    endRadius: 640
                )

                VStack(spacing: 24) {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(Color.cyan.opacity(0.14))
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.cyan)
                        }
                        .frame(width: 62, height: 62)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Text("Open apps")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))

                                Text("\(windows.count)")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }

                            Text("Choose a preview to return · point at × to close")
                                .font(.system(size: 17, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.56))
                        }

                        Spacer()
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
                        }
                    }
                }
                .padding(32)
                .frame(width: min(proxy.size.width * 0.9, 1_560))
                .background(
                    Color(red: 0.035, green: 0.045, blue: 0.065).opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 38, style: .continuous)
                )
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.2), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
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
        let hoveredAction = inputRouter.appSwitcherAction()
        let isHovered = hoveredAction?.windowID == window.id
        let isCloseHovered = hoveredAction == .close(window.id)
        let isActive = workspace.activeWindowID == window.id
        let accent = accentColor(for: window)

        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                appPreview(
                    for: window,
                    accent: accent,
                    isActive: isActive,
                    height: max(height - 78, 74)
                )

                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.17))
                        Image(systemName: window.systemImage)
                            .font(.system(size: min(22, height * 0.11), weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.title)
                            .font(.system(size: min(18, height * 0.09), weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(statusTitle(for: window, isActive: isActive))
                            .foregroundStyle(isActive ? .cyan : .white.opacity(0.46))
                            .appSwitcherStatusBadge()
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.72 : 0.24))
                }
                .padding(.horizontal, 14)
                .frame(height: 72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                isHovered ? accent.opacity(0.12) : Color.black.opacity(0.3),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        isHovered ? accent : isActive ? Color.cyan.opacity(0.72) : Color.white.opacity(0.12),
                        lineWidth: isHovered || isActive ? 2.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .appSwitcherHitTarget(.focus(window.id), in: Self.coordinateSpace)

            ZStack {
                Circle()
                    .fill(isCloseHovered ? Color.red : Color.black.opacity(0.72))
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: 46, height: 46)
            .overlay {
                Circle()
                    .stroke(isCloseHovered ? Color.white.opacity(0.72) : Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: isCloseHovered ? .red.opacity(0.5) : .black.opacity(0.34), radius: 10, y: 5)
            .scaleEffect(isCloseHovered ? 1.12 : 1)
            .offset(x: 10, y: -10)
            .contentShape(Circle())
            .appSwitcherHitTarget(.close(window.id), in: Self.coordinateSpace)
            .accessibilityLabel("Close \(window.title)")
        }
        .scaleEffect(isHovered ? 1.035 : 1)
        .shadow(color: isHovered ? accent.opacity(0.34) : .clear, radius: 20)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isCloseHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.title)
        .accessibilityValue(isActive ? "Active" : window.isMinimized ? "Minimized" : "Open")
        .accessibilityHint("Open this app")
    }

    private func appPreview(
        for window: WorkspaceWindow,
        accent: Color,
        isActive: Bool,
        height: CGFloat
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    accent.opacity(0.28),
                    Color(red: 0.055, green: 0.065, blue: 0.09),
                    .black.opacity(0.72),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(.red.opacity(0.76))
                    Circle().fill(.yellow.opacity(0.76))
                    Circle().fill(.green.opacity(0.76))
                    Spacer()
                    Capsule()
                        .fill(.white.opacity(0.13))
                        .frame(width: 46, height: 5)
                }
                .frame(height: 26)
                .padding(.horizontal, 10)
                .background(.black.opacity(0.2))

                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.035))
                        .padding(12)

                    Image(systemName: window.systemImage)
                        .font(.system(size: min(68, height * 0.36), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: accent.opacity(0.6), radius: 24)

                    VStack {
                        Spacer()
                        HStack {
                            Text(isActive ? "CURRENT" : window.isMinimized ? "PAUSED" : "RUNNING")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .tracking(1.2)
                                .foregroundStyle(isActive ? .cyan : .white.opacity(0.58))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(.black.opacity(0.48), in: Capsule())
                            Spacer()
                        }
                        .padding(12)
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 23,
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 8,
                topTrailingRadius: 23,
                style: .continuous
            )
        )
    }

    private func statusTitle(for window: WorkspaceWindow, isActive: Bool) -> String {
        if isActive { return "ACTIVE" }
        return window.isMinimized ? "MINIMIZED" : "OPEN"
    }

    private func accentColor(for window: WorkspaceWindow) -> Color {
        switch window.kind {
        case .browser: .cyan
        case .maps: .green
        case .gallery: .orange
        case .youtube: .red
        case .remoteDesktop: .purple
        }
    }

    private static func columnCount(for itemCount: Int) -> Int {
        guard itemCount > 4 else { return max(itemCount, 1) }
        return max(1, Int(ceil(sqrt(Double(itemCount) * 16 / 9))))
    }

    private static func cardHeight(rowCount: Int, canvasHeight: CGFloat) -> CGFloat {
        let availableHeight = max(canvasHeight * 0.66 - 100, 150)
        let totalSpacing = CGFloat(max(rowCount - 1, 0)) * 20
        return min(330, max(150, (availableHeight - totalSpacing) / CGFloat(rowCount)))
    }
}

private struct AppSwitcherHitFramePreferenceKey: PreferenceKey {
    static let defaultValue: [AppSwitcherAction: CGRect] = [:]

    static func reduce(
        value: inout [AppSwitcherAction: CGRect],
        nextValue: () -> [AppSwitcherAction: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func appSwitcherHitTarget(_ action: AppSwitcherAction, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AppSwitcherHitFramePreferenceKey.self,
                    value: [action: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }

    func appSwitcherStatusBadge() -> some View {
        font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.2)
    }
}

private struct WidgetPickerOverlay: View {
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.activeScenario.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                Text("Widgets")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 40)

            ForEach(DashboardWidgetKind.allCases) { kind in
                let isIncluded = dashboard.containsWidget(kind)
                Button {
                    dashboard.toggleWidget(kind)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: kind.systemImage)
                        Text(kind.title)
                            .lineLimit(1)
                        Image(systemName: isIncluded ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(isIncluded ? Color.orange : Color.white.opacity(0.45))
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isIncluded ? 0.96 : 0.72))
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(
                        isIncluded ? Color.orange.opacity(0.13) : Color.white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isIncluded ? Color.orange.opacity(0.4) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .statusBarHitTarget(.toggleWidget(kind), in: SpatialCanvasView.coordinateSpace)
                .accessibilityLabel("\(isIncluded ? "Remove" : "Add") \(kind.title) widget")
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.11), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .fixedSize()
    }
}

private struct ScenarioPickerOverlay: View {
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DashboardScenario.allCases) { scenario in
                let isActive = dashboard.activeScenario == scenario
                Button {
                    dashboard.selectScenario(scenario)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: scenario.systemImage)
                        Text(scenario.title)
                        if isActive {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.68))
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(
                        isActive ? Color.orange.opacity(0.14) : Color.white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .statusBarHitTarget(.selectDashboardScenario(scenario), in: SpatialCanvasView.coordinateSpace)
                .accessibilityLabel("\(scenario.title) scenario")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.11), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .fixedSize()
    }
}

private struct WorkspaceStatusBar: View {
    let environment: AppEnvironment
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DashboardStore.self) private var dashboard
    @Environment(InputRouter.self) private var inputRouter
    @Environment(HeadPoseController.self) private var headPose
    @State private var batteryLevel: Int?
    @State private var batteryState: UIDevice.BatteryState = .unknown

    var body: some View {
        HStack(spacing: 0) {
            Button {
                dashboard.toggleScenarioPicker()
            } label: {
                HStack(spacing: 8) {
                    Label(dashboard.activeScenario.title, systemImage: dashboard.activeScenario.systemImage)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .statusBarSection()
            .statusBarHitTarget(.toggleDashboardScenarioPicker, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Dashboard scenario")
            .accessibilityValue(dashboard.activeScenario.title)
            .accessibilityHint("Choose a scenario")

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
                environment.toggleDashboard()
            } label: {
                Image(systemName: "house.fill")
            }
            .statusBarButton(isSelected: workspace.isDashboardPresented)
            .statusBarHitTarget(.dashboard, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Dashboard")

            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1, height: 24)
                .padding(.horizontal, 3)

            Button {
                environment.showWidgets()
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .statusBarButton(isSelected: workspace.presentationMode == .widgets)
            .statusBarHitTarget(.widgets, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Widgets view")

            Button {
                environment.showWindows()
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .statusBarButton(isSelected: workspace.presentationMode == .windows)
            .statusBarHitTarget(.windows, in: SpatialCanvasView.coordinateSpace)
            .accessibilityLabel("Windows view")

            if workspace.presentationMode == .widgets, !workspace.isDashboardPresented {
                Button {
                    dashboard.toggleWidgetPicker()
                } label: {
                    Image(systemName: dashboard.isWidgetPickerPresented ? "xmark" : "plus")
                }
                .statusBarButton(isSelected: dashboard.isWidgetPickerPresented)
                .statusBarHitTarget(.toggleWidgetPicker, in: SpatialCanvasView.coordinateSpace)
                .accessibilityLabel(dashboard.isWidgetPickerPresented ? "Close widget picker" : "Add or remove widgets")
            }

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
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
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
            let isNavigationLens = window.kind == .maps

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
                    .background(isNavigationLens ? Color.clear : Color.black)
                    .clipShape(surfaceShape)
                    .overlay {
                        if !isNavigationLens {
                            SpatialWindowCurvatureOverlay(amount: curvature)
                                .clipShape(surfaceShape)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if !isNavigationLens {
                            surfaceShape
                                .strokeBorder(
                                    isMoveMode ? Color.purple.opacity(0.9) : Color.white.opacity(isFocused ? 0.22 : 0.12),
                                    lineWidth: isMoveMode ? 2.5 : 1
                                )
                        }
                    }
                    .overlay {
                        SpatialWindowResizeOverlay(
                            windowID: window.id,
                            isFocused: isFocused,
                            curvature: curvature
                        )
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

private struct SpatialWindowResizeOverlay: View {
    @Environment(InputRouter.self) private var inputRouter

    let windowID: UUID
    let isFocused: Bool
    let curvature: CGFloat

    var body: some View {
        GeometryReader { proxy in
            if isFocused,
               inputRouter.isCursorVisible,
               let hover = inputRouter.resizeIndicator(in: windowID) {
                SpatialWindowResizeHandle(
                    edge: hover.edge,
                    curvature: curvature
                )
                .position(position(for: hover, in: proxy.size))
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.16), value: inputRouter.resizeIndicator(in: windowID)?.edge)
    }

    private func position(for hover: WindowResizeHover, in size: CGSize) -> CGPoint {
        let handleRadius: CGFloat = 32
        switch hover.edge {
        case .leading:
            return CGPoint(
                x: handleRadius,
                y: edgePosition(hover.position, length: size.height, inset: handleRadius)
            )
        case .trailing:
            return CGPoint(
                x: max(handleRadius, size.width - handleRadius),
                y: edgePosition(hover.position, length: size.height, inset: handleRadius)
            )
        case .top:
            return CGPoint(
                x: edgePosition(hover.position, length: size.width, inset: handleRadius),
                y: handleRadius
            )
        case .bottom:
            return CGPoint(
                x: edgePosition(hover.position, length: size.width, inset: handleRadius),
                y: max(handleRadius, size.height - handleRadius)
            )
        }
    }

    private func edgePosition(_ position: CGFloat, length: CGFloat, inset: CGFloat) -> CGFloat {
        guard length > inset * 2 else { return length / 2 }
        return (position * length).clamped(to: inset ... length - inset)
    }
}

private struct SpatialWindowResizeHandle: View {
    let edge: WindowResizeEdge
    let curvature: CGFloat

    var body: some View {
        ZStack {
            SpatialResizeArc()
                .stroke(
                    .black.opacity(0.56),
                    style: StrokeStyle(lineWidth: 15, lineCap: .round)
                )

            SpatialResizeArc()
                .stroke(
                    .white.opacity(0.96),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
        }
        .frame(width: 64, height: 64)
        .rotationEffect(rotation)
        .shadow(color: .black.opacity(0.5), radius: 10 + curvature * 8)
        .accessibilityElement()
        .accessibilityLabel("Resize window")
        .accessibilityHint("Drag away from the window edge to enlarge it")
    }

    private var rotation: Angle {
        switch edge {
        case .trailing:
            .zero
        case .leading:
            .degrees(180)
        case .top:
            .degrees(-90)
        case .bottom:
            .degrees(90)
        }
    }
}

private struct SpatialResizeArc: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.14
        let radius = max(0, min(rect.width, rect.height) - inset * 2)
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.minX + inset, y: rect.maxY - inset),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
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
