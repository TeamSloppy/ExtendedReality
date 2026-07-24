import SwiftUI
import UIKit

enum SpatialDashboardContentMode: Equatable {
    case widgets
    case dashboard
}

struct SpatialDashboardView: View {
    let environment: AppEnvironment
    let mode: SpatialDashboardContentMode
    let isInteractive: Bool
    @Environment(DashboardStore.self) private var dashboard
    @Environment(InputRouter.self) private var inputRouter

    var body: some View {
        GeometryReader { proxy in
            let items = mode == .widgets ? dashboard.widgets : dashboard.launchers
            let presentations = mode == .widgets
                ? items.map {
                    DashboardProjection.presentation(
                        for: $0,
                        in: proxy.size,
                        rotationDegrees: 0
                    )
                }
                : DashboardApplicationProjection.presentations(for: items, in: proxy.size)
            let inputLayouts = Dictionary(
                uniqueKeysWithValues: presentations.map { presentation in
                    (
                        presentation.id,
                        DashboardItemInputLayout(
                            center: CGPoint(
                                x: presentation.center.x / max(proxy.size.width, 1),
                                y: presentation.center.y / max(proxy.size.height, 1)
                            ),
                            size: CGSize(
                                width: presentation.size.width / max(proxy.size.width, 1),
                                height: presentation.size.height / max(proxy.size.height, 1)
                            ),
                            rotationRadians: presentation.rotationDegrees * .pi / 180,
                            zIndex: presentation.item.placement.zIndex
                        )
                    )
                }
            )

            ZStack {
                dashboardBackdrop

                if mode == .dashboard {
                    DashboardHero(
                        isDisplayConnected: environment.workspace.isExternalDisplayConnected,
                        isTracking: environment.headPose.isTracking
                    )
                    .frame(width: min(proxy.size.width * 0.74, 920))
                    .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.205)
                    .zIndex(100)

                    DashboardScenarioIndicator(activeScenario: dashboard.activeScenario)
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.925)
                        .zIndex(100)
                }

                if presentations.isEmpty {
                    ContentUnavailableView(
                        mode == .widgets ? "No widgets" : "No dashboard apps",
                        systemImage: mode == .widgets ? "rectangle.3.group" : "app.dashed",
                        description: Text(
                            mode == .widgets
                                ? "Add widgets from the iPhone controller."
                                : "Add applications from the iPhone controller."
                        )
                    )
                    .foregroundStyle(.white.opacity(0.62))
                } else {
                    ForEach(presentations.sorted(by: { $0.item.placement.zIndex < $1.item.placement.zIndex })) { presentation in
                        DashboardFreeformItemView(
                            item: presentation.item,
                            isHovered: inputRouter.dashboardItem() == presentation.id,
                            isSelected: dashboard.selectedItemID == presentation.id,
                            isArranging: environment.workspace.controlMode == .arrange,
                            dashboard: dashboard,
                            systemData: environment.systemData,
                            liveTranslation: environment.liveTranslation
                        ) {
                            environment.activateDashboardItem(presentation.id)
                        }
                        .frame(width: presentation.size.width, height: presentation.size.height)
                        .rotationEffect(.degrees(presentation.rotationDegrees))
                        .position(presentation.center)
                        .zIndex(Double(presentation.item.placement.zIndex))
                    }
                }
            }
            .onChange(of: inputLayouts, initial: true) { _, layouts in
                guard isInteractive else { return }
                inputRouter.updateDashboardLayouts(layouts)
            }
            .onChange(of: isInteractive) { _, isInteractive in
                guard isInteractive else { return }
                inputRouter.updateDashboardLayouts(inputLayouts)
            }
            .onDisappear {
                dashboard.clearSelection()
            }
        }
    }

    private var dashboardBackdrop: some View {
        Group {
            if mode == .dashboard {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.52)

                    Color.black.opacity(0.46)

                    LinearGradient(
                        colors: [
                            Color(red: 0.02, green: 0.08, blue: 0.14).opacity(0.18),
                            .clear,
                            Color.black.opacity(0.24),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    RadialGradient(
                        colors: [Color.cyan.opacity(0.055), .clear],
                        center: UnitPoint(x: 0.18, y: 0.32),
                        startRadius: 10,
                        endRadius: 560
                    )

                    RadialGradient(
                        colors: [Color.purple.opacity(0.05), .clear],
                        center: UnitPoint(x: 0.82, y: 0.64),
                        startRadius: 10,
                        endRadius: 620
                    )

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.2)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
            } else {
                Color.black
            }
        }
    }
}

private struct DashboardHero: View {
    let isDisplayConnected: Bool
    let isTracking: Bool

    var body: some View {
        VStack(spacing: 10) {
            PeriodicDateView(every: .seconds(1)) { date in
                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 112, weight: .heavy, design: .rounded))
                    .tracking(-6)
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.66, green: 0.86, blue: 1),
                                Color(red: 0.22, green: 0.52, blue: 1),
                                Color(red: 0.15, green: 0.9, blue: 0.75),
                                Color(red: 0.68, green: 0.85, blue: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: .blue.opacity(0.22), radius: 22, y: 10)
                    .contentTransition(.numericText())
                    .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
            }

            DashboardDeviceStatus(
                isDisplayConnected: isDisplayConnected,
                isTracking: isTracking
            )
        }
        .minimumScaleFactor(0.62)
    }
}

private struct DashboardDeviceStatus: View {
    let isDisplayConnected: Bool
    let isTracking: Bool
    @State private var batteryLevel: Int?
    @State private var batteryState: UIDevice.BatteryState = .unknown

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: isDisplayConnected ? "wifi" : "wifi.slash")
                .foregroundStyle(isDisplayConnected ? .white : .orange)
                .accessibilityLabel(isDisplayConnected ? "Display connected" : "Display disconnected")

            Image(systemName: "eyeglasses")
                .foregroundStyle(isTracking ? .cyan : .white.opacity(0.48))
                .accessibilityLabel(isTracking ? "Head tracking active" : "Head tracking inactive")

            HStack(spacing: 8) {
                Image(systemName: batterySymbol)
                Text(batteryLevel.map { "\($0)%" } ?? "—")
                    .monospacedDigit()
            }
            .foregroundStyle(batteryColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("iPhone battery")
            .accessibilityValue(batteryLevel.map { "\($0) percent" } ?? "Unavailable")
        }
        .font(.system(size: 21, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 30)
        .frame(height: 58)
        .background(Color.black.opacity(0.58), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .shadow(color: .black.opacity(0.46), radius: 24, y: 12)
        .fixedSize()
        .onAppear(perform: startBatteryMonitoring)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            refreshBatteryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            refreshBatteryState()
        }
    }

    private var batterySymbol: String {
        guard let batteryLevel else { return "battery.0percent" }
        return switch batteryLevel {
        case 76 ... 100: "battery.100percent"
        case 51 ... 75: "battery.75percent"
        case 26 ... 50: "battery.50percent"
        case 1 ... 25: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private var batteryColor: Color {
        if batteryState == .charging || batteryState == .full {
            return .green
        }
        if let batteryLevel, batteryLevel <= 20 {
            return .red
        }
        return .white.opacity(0.88)
    }

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBatteryState()
    }

    private func refreshBatteryState() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? Int((level * 100).rounded()) : nil
        batteryState = UIDevice.current.batteryState
    }
}

private struct DashboardScenarioIndicator: View {
    let activeScenario: DashboardScenario

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DashboardScenario.allCases) { scenario in
                Capsule()
                    .fill(
                        scenario == activeScenario
                            ? Color.white.opacity(0.92)
                            : Color.white.opacity(0.24)
                    )
                    .frame(width: scenario == activeScenario ? 24 : 8, height: 8)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color.black.opacity(0.24), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dashboard scenario")
        .accessibilityValue(activeScenario.title)
    }
}

private struct DashboardFreeformItemView: View {
    let item: DashboardItem
    let isHovered: Bool
    let isSelected: Bool
    let isArranging: Bool
    let dashboard: DashboardStore
    let systemData: SystemDataStore
    let liveTranslation: LiveTranslationController
    let action: () -> Void

    var body: some View {
        Group {
            switch item.content {
            case .app, .pwa, .bookmark:
                DashboardLauncherTile(item: item, isHovered: isHovered, action: action)
            case .widget:
                DashboardWidgetCard(
                    item: item,
                    isHovered: isHovered,
                    dashboard: dashboard,
                    systemData: systemData,
                    liveTranslation: liveTranslation,
                    action: action
                )
            }
        }
        .overlay {
            if isArranging, isSelected {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                    .padding(-7)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHint(isArranging ? "Move with one finger and resize with a pinch" : "Open from dashboard")
    }
}

private struct DashboardLauncherTile: View {
    let item: DashboardItem
    let isHovered: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let iconDiameter = min(proxy.size.width * 0.72, proxy.size.height * 0.65)
            Button(action: action) {
                VStack(spacing: max(6, proxy.size.height * 0.045)) {
                    icon(diameter: iconDiameter)
                        .frame(width: iconDiameter, height: iconDiameter)
                        .background(iconGradient, in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.44), .white.opacity(0.06)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                        .overlay {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.20), .clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                                .padding(3)
                        }
                        .overlay {
                            if isHovered {
                                Circle()
                                    .stroke(accentColor.opacity(0.92), lineWidth: 4)
                                    .padding(-7)
                            }
                        }
                        .overlay(alignment: .top) {
                            if isHovered {
                                Circle()
                                    .fill(.white.opacity(0.96))
                                    .frame(width: 13, height: 13)
                                    .overlay {
                                        Circle().stroke(accentColor.opacity(0.75), lineWidth: 3)
                                    }
                                    .shadow(color: accentColor.opacity(0.8), radius: 8)
                                    .offset(y: -18)
                            }
                        }
                        .shadow(
                            color: isHovered ? accentColor.opacity(0.52) : accentColor.opacity(0.18),
                            radius: isHovered ? 24 : 15,
                            y: 10
                        )

                    Text(title)
                        .font(.system(size: min(18, max(12, proxy.size.width * 0.1)), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(isHovered ? 1 : 0.76))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .scaleEffect(isHovered ? 1.055 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .accessibilityLabel(title)
        .accessibilityHint("Open from dashboard")
    }

    @ViewBuilder
    private func icon(diameter: CGFloat) -> some View {
        switch item.content {
        case .app(let kind):
            Image(systemName: kind.systemImage)
                .font(.system(size: diameter * 0.39, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.24), radius: 4, y: 3)
        case .pwa(let installation):
            Text(installation.manifest.monogram)
                .font(.system(
                    size: diameter * (installation.manifest.monogram.count > 1 ? 0.25 : 0.36),
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.24), radius: 4, y: 3)
        case .bookmark(let bookmark):
            Text(bookmark.monogram)
                .font(.system(
                    size: diameter * (bookmark.monogram.count > 1 ? 0.25 : 0.36),
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.24), radius: 4, y: 3)
        case .widget:
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

    private var iconGradient: LinearGradient {
        let colors: [Color]
        switch item.content {
        case .app(.gallery):
            colors = [.yellow, .orange, .pink]
        case .app(.browser):
            colors = [Color(red: 0.20, green: 0.82, blue: 1), .blue, .indigo]
        case .app(.maps):
            colors = [Color(red: 0.22, green: 0.88, blue: 0.62), .green, .teal]
        case .app(.youtube):
            colors = [Color(red: 1, green: 0.22, blue: 0.30), .red, Color(red: 0.66, green: 0.02, blue: 0.10)]
        case .app(.remoteDesktop):
            colors = [Color(red: 0.67, green: 0.38, blue: 1), .purple, .indigo]
        case .pwa:
            colors = [Color(red: 0.28, green: 0.67, blue: 1), .blue, .purple]
        case .bookmark(let bookmark):
            colors = [bookmark.accent.color.opacity(0.92), bookmark.accent.color, .black.opacity(0.68)]
        case .widget:
            colors = [.orange, .pink]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var accentColor: Color {
        switch item.content {
        case .app(.gallery): .orange
        case .app(.browser): .cyan
        case .app(.maps): .green
        case .app(.youtube): .red
        case .app(.remoteDesktop): .purple
        case .pwa: .blue
        case .bookmark(let bookmark): bookmark.accent.color
        case .widget: .orange
        }
    }
}

private struct DashboardWidgetCard: View {
    let item: DashboardItem
    let isHovered: Bool
    let dashboard: DashboardStore
    let systemData: SystemDataStore
    let liveTranslation: LiveTranslationController
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Group {
                if case .widget(let kind) = item.content {
                    switch kind {
                    case .calendar:
                        calendarWidget
                    case .health:
                        healthWidget
                    case .focus:
                        focusWidget
                    case .translation:
                        liveTranslationWidget
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .topLeading)
            .padding(18)
            .background(Color(red: 0.045, green: 0.047, blue: 0.06).opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isHovered ? Color.orange : Color.white.opacity(0.12), lineWidth: isHovered ? 2 : 1)
            }
            .shadow(color: isHovered ? .orange.opacity(0.22) : .black.opacity(0.34), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.025 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
    }

    private var calendarWidget: some View {
        PeriodicDateView(every: .seconds(60)) { date in
            HStack(alignment: .center, spacing: 18) {
                VStack(spacing: 0) {
                    Text(date, format: .dateTime.month(.abbreviated))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .textCase(.uppercase)
                    Text(date, format: .dateTime.day())
                        .font(.system(size: 43, weight: .light, design: .rounded))
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    widgetTitle("Next", systemImage: "calendar")
                    Text(date, format: .dateTime.weekday(.wide))
                        .font(.title3.weight(.semibold))
                    Text("Date overview")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var healthWidget: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(.pink.opacity(0.22), lineWidth: 9)
                Image(systemName: "heart.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.pink)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 8) {
                widgetTitle("Health", systemImage: "waveform.path.ecg")
                Text(healthHeadline)
                    .font(.title3.weight(.semibold))
                Text(healthDetail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer(minLength: 0)
        }
    }

    private var focusWidget: some View {
        PeriodicDateView(
            every: .seconds(1),
            isEnabled: dashboard.focusEndDate != nil,
            updatesUntil: dashboard.focusEndDate
        ) { date in
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(.orange.opacity(0.2), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: focusProgress(at: date))
                        .stroke(.orange, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: isFocusRunning(at: date) ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 7) {
                    widgetTitle(
                        systemData.focusProfile?.title ?? "Focus",
                        systemImage: systemData.focusProfile?.systemImage ?? "timer"
                    )
                    Text(formattedFocusTime(at: date))
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(focusDetail(at: date))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var liveTranslationWidget: some View {
        let translation = liveTranslation
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(translation.state.isActive ? Color.cyan.opacity(0.2) : Color.white.opacity(0.07))
                Image(systemName: translation.state.isActive ? "waveform.and.mic" : "captions.bubble.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(translation.state.isActive ? .cyan : .white.opacity(0.72))
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text("LIVE TRANSLATION")
                    Text(translation.languagePairLabel)
                        .foregroundStyle(.white.opacity(0.54))
                }
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.cyan)

                Text(translation.translatedText.isEmpty ? "Local subtitles" : translation.translatedText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)

                Text(translation.sourceText.isEmpty ? translation.statusText : translation.sourceText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Live translation, \(translation.languagePairLabel)")
        .accessibilityValue(translation.translatedText.isEmpty ? translation.statusText : translation.translatedText)
        .accessibilityHint(translation.state.isActive ? "Stop local subtitles" : "Start local subtitles")
    }

    private func widgetTitle(_ title: String, systemImage: String) -> some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(.orange)
    }

    private func formattedFocusTime(at date: Date) -> String {
        let remaining = Int(dashboard.focusTimeRemaining(at: date).rounded(.down))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    private func focusProgress(at date: Date) -> CGFloat {
        CGFloat(dashboard.focusTimeRemaining(at: date) / (25 * 60)).clamped(to: 0 ... 1)
    }

    private func isFocusRunning(at date: Date) -> Bool {
        guard let focusEndDate = dashboard.focusEndDate else { return false }
        return focusEndDate > date
    }

    private var healthHeadline: String {
        guard let summary = systemData.healthSummary else { return "Heart rate" }
        guard let heartRate = summary.latestHeartRateBPM else { return "No heart rate yet" }
        return "\(Int(heartRate.rounded())) bpm"
    }

    private var healthDetail: String {
        guard let summary = systemData.healthSummary else {
            return systemData.healthAuthorization == .requested || systemData.healthAuthorization == .authorized
                ? "Tap to refresh Health data"
                : "Tap to connect Apple Health"
        }
        return "\(summary.steps.formatted()) steps · \(Int(summary.activeEnergyKilocalories.rounded())) kcal"
    }

    private func focusDetail(at date: Date) -> String {
        if let focusProfile = systemData.focusProfile {
            return isFocusRunning(at: date)
                ? "\(focusProfile.title) · tap to pause timer"
                : "System Focus is active"
        }
        if systemData.isFocused == true {
            return isFocusRunning(at: date) ? "Focus silences alerts · tap to pause" : "Focus silences notifications"
        }
        if systemData.focusAuthorization != .authorized {
            return "Connect Focus Status in Settings"
        }
        return isFocusRunning(at: date) ? "Tap to pause" : "25 minute session"
    }
}

/// Keeps time-driven invalidations local to the text or widget that needs them.
/// `TimelineView` caused the containing external-display graph to continuously
/// re-render on iOS 27, turning each one-second tick into a visible main-thread hang.
struct PeriodicDateView<Content: View>: View {
    let interval: Duration
    let isEnabled: Bool
    let updatesUntil: Date?
    @ViewBuilder let content: (Date) -> Content

    @State private var date = Date.now

    init(
        every interval: Duration,
        isEnabled: Bool = true,
        updatesUntil: Date? = nil,
        @ViewBuilder content: @escaping (Date) -> Content
    ) {
        self.interval = interval
        self.isEnabled = isEnabled
        self.updatesUntil = updatesUntil
        self.content = content
    }

    var body: some View {
        content(date)
            .task(id: ScheduleID(isEnabled: isEnabled, updatesUntil: updatesUntil)) {
                date = .now
                guard isEnabled else { return }

                while !Task.isCancelled {
                    if let updatesUntil, date >= updatesUntil { return }

                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    date = .now
                }
            }
    }

    private struct ScheduleID: Hashable {
        let isEnabled: Bool
        let updatesUntil: Date?
    }
}

private extension DashboardAccent {
    var color: Color {
        switch self {
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

#if DEBUG
#Preview("Spatial Dashboard") {
    let environment = AppEnvironment.preview(windowCount: 0, showsDashboard: true)
    SpatialDashboardView(environment: environment, mode: .dashboard, isInteractive: true)
        .previewEnvironment(environment)
        .frame(width: 1_920, height: 1_080)
        .preferredColorScheme(.dark)
}
#endif
