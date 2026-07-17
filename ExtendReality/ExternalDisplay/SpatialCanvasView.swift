import SwiftUI
import UIKit

struct SpatialCanvasView: View {
    fileprivate static let coordinateSpace = "spatial.canvas"

    let environment: AppEnvironment
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(InputRouter.self) private var inputRouter
    @Environment(HeadPoseController.self) private var headPose

    var body: some View {
        GeometryReader { proxy in
            let visibleWindows = workspace.windows.filter { !$0.isMinimized }
            ZStack {
                canvasBackground

                if visibleWindows.isEmpty {
                    SpatialDashboardView(environment: environment)
                        .transition(.opacity)
                        .zIndex(0)
                }

                ForEach(visibleWindows) { window in
                    let frame = WindowProjection.frame(
                        for: window.transform,
                        in: CGRect(origin: .zero, size: proxy.size),
                        headPose: headPose.pose
                    )
                    SpatialWindowChrome(
                        window: window,
                        isFocused: workspace.activeWindowID == window.id,
                        canvasFrame: frame,
                        viewportSize: proxy.size,
                        rotation: .degrees(-headPose.pose.roll),
                        environment: environment
                    )
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.degrees(-headPose.pose.roll))
                    .position(x: frame.midX, y: frame.midY)
                    .zIndex(Double(window.zIndex))
                }

                VStack {
                    WorkspaceStatusBar(environment: environment)
                    Spacer()
                }
                .padding(.top, max(24, proxy.safeAreaInsets.top + 12))
                .padding(.horizontal, 32)
                .zIndex(10_000)

                if workspace.isAppSwitcherPresented {
                    AppSwitcherOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(15_000)
                }

                canvasCursor(in: proxy.size)
                    .zIndex(20_000)
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(StatusBarHitFramePreferenceKey.self) { frames in
                inputRouter.updateStatusBarHitFrames(frames, in: proxy.size)
            }
            .onDisappear {
                inputRouter.clearStatusBarHitFrames()
            }
            .clipped()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func canvasCursor(in size: CGSize) -> some View {
        let isHoveringInteractiveTarget = inputRouter.isHoveringInteractiveTarget(
            in: workspace.activeWindowID
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
            Image(systemName: window.kind.systemImage)
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
            Image(systemName: "eyeglasses")
                .foregroundStyle(headPose.isTracking ? .cyan : .orange)
                .accessibilityLabel("Head tracking")
                .accessibilityValue(headPose.statusText)

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

    private var controls: some View {
        HStack(spacing: 4) {
            Button {
                environment.showDashboard()
            } label: {
                Image(systemName: "house.fill")
            }
            .statusBarButton(isSelected: workspace.activeWindowID == nil)
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
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: window.kind.systemImage)
                    Text(window.title)
                        .lineLimit(1)
                    Spacer()
                    Circle()
                        .fill(isFocused ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: WindowChromeLayout.titleBarHeight)
                .background(.ultraThinMaterial)

                SurfaceHostView(window: window, environment: environment)

                SpatialWindowOrnament(
                    windowID: window.id,
                    isFocused: isFocused,
                    viewportSize: viewportSize,
                    environment: environment
                )
            }
            .onAppear {
                environment.inputRouter.updateWindowLayout(inputLayout, for: window.id)
            }
            .onChange(of: inputLayout) { _, layout in
                environment.inputRouter.updateWindowLayout(layout, for: window.id)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isFocused ? Color.cyan : Color.white.opacity(0.16), lineWidth: isFocused ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.75), radius: 24, y: 12)
        .onDisappear {
            environment.inputRouter.removeWindowLayout(for: window.id)
        }
    }
}

private struct SpatialWindowOrnament: View {
    let windowID: UUID
    let isFocused: Bool
    let viewportSize: CGSize
    let environment: AppEnvironment
    @State private var previousDragTranslation = CGSize.zero
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 0) {
            ornamentButton(
                title: "Close",
                systemImage: "xmark",
                tint: .red
            ) {
                environment.closeWindow(windowID)
            }

            ZStack {
                Color.clear
                Capsule()
                    .fill(isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.38))
                    .frame(width: 112, height: 6)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .accessibilityElement()
            .accessibilityLabel("Move window")
            .accessibilityHint("Drag to reposition the window")

            ornamentButton(
                title: "Minimize",
                systemImage: "minus",
                tint: .yellow
            ) {
                environment.minimizeWindow(windowID)
            }
        }
        .frame(height: WindowChromeLayout.ornamentHeight)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    previousDragTranslation = .zero
                    environment.workspace.focus(windowID)
                }

                let delta = CGSize(
                    width: value.translation.width - previousDragTranslation.width,
                    height: value.translation.height - previousDragTranslation.height
                )
                previousDragTranslation = value.translation

                environment.workspace.moveWindow(
                    windowID,
                    normalizedDelta: CGVector(
                        dx: delta.width / max(viewportSize.width, 1) * 2.5,
                        dy: delta.height / max(viewportSize.height, 1) * 2.5
                    )
                )
            }
            .onEnded { _ in
                previousDragTranslation = .zero
                isDragging = false
            }
    }

    private func ornamentButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: WindowChromeLayout.controlWidth, height: WindowChromeLayout.ornamentHeight)
            .contentShape(Rectangle())
            .background {
                Circle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle().stroke(.white.opacity(0.13), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
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
