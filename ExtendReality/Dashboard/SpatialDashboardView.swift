import SwiftUI

struct SpatialDashboardView: View {
    let environment: AppEnvironment
    @Environment(DashboardStore.self) private var dashboard
    @Environment(InputRouter.self) private var inputRouter
    @Environment(HeadPoseController.self) private var headPose

    var body: some View {
        GeometryReader { proxy in
            let rotation = DashboardProjection.stabilizationRotation(
                for: headPose.pose,
                isTracking: headPose.isTracking
            )
            let presentations = dashboard.items.map {
                DashboardProjection.presentation(
                    for: $0,
                    in: proxy.size,
                    rotationDegrees: rotation
                )
            }
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

                if presentations.isEmpty {
                    ContentUnavailableView(
                        "No dashboard items",
                        systemImage: "rectangle.3.group",
                        description: Text("Add widgets and shortcuts from the iPhone controller.")
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
                            systemData: environment.systemData
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
                inputRouter.updateDashboardLayouts(layouts)
            }
            .onDisappear {
                inputRouter.clearDashboardHitFrames()
                dashboard.clearSelection()
            }
        }
    }

    private var dashboardBackdrop: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.orange.opacity(0.08), .clear],
                center: UnitPoint(x: 0.17, y: 0.52),
                startRadius: 10,
                endRadius: 430
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.05), .clear],
                center: UnitPoint(x: 0.78, y: 0.22),
                startRadius: 10,
                endRadius: 520
            )
        }
    }
}

private struct DashboardFreeformItemView: View {
    let item: DashboardItem
    let isHovered: Bool
    let isSelected: Bool
    let isArranging: Bool
    let dashboard: DashboardStore
    let systemData: SystemDataStore
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
        Button(action: action) {
            VStack(spacing: 12) {
                icon
                    .frame(width: 104, height: 104)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                isHovered ? accentColor : Color.white.opacity(0.13),
                                lineWidth: isHovered ? 4 : 1
                            )
                    }
                    .shadow(color: isHovered ? accentColor.opacity(0.38) : .black.opacity(0.42), radius: 18, y: 8)

                Text(title)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 151)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.055 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .accessibilityLabel(title)
        .accessibilityHint("Open from dashboard")
    }

    @ViewBuilder
    private var icon: some View {
        switch item.content {
        case .app(let kind):
            Image(systemName: kind.systemImage)
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(accentColor)
        case .pwa(let installation):
            Text(installation.manifest.monogram)
                .font(.system(size: installation.manifest.monogram.count > 1 ? 28 : 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(accentColor.opacity(0.78), in: Circle().inset(by: 13))
        case .bookmark(let bookmark):
            Text(bookmark.monogram)
                .font(.system(size: bookmark.monogram.count > 1 ? 28 : 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(accentColor.opacity(0.78), in: Circle().inset(by: 13))
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
                    widgetTitle("Focus", systemImage: "timer")
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
        guard let summary = systemData.healthSummary else { return "Activity summary" }
        return "\(summary.steps.formatted()) steps"
    }

    private var healthDetail: String {
        guard let summary = systemData.healthSummary else {
            return systemData.healthAuthorization == .requested || systemData.healthAuthorization == .authorized
                ? "No activity data available today"
                : "Connect Health in Settings"
        }
        var values = ["\(Int(summary.activeEnergyKilocalories.rounded())) kcal"]
        if let heartRate = summary.latestHeartRateBPM {
            values.append("\(Int(heartRate.rounded())) bpm")
        }
        return values.joined(separator: " · ")
    }

    private func focusDetail(at date: Date) -> String {
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
    SpatialDashboardView(environment: environment)
        .previewEnvironment(environment)
        .frame(width: 1_920, height: 1_080)
        .preferredColorScheme(.dark)
}
#endif
