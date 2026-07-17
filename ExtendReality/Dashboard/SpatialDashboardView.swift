import SwiftUI

struct SpatialDashboardView: View {
    let environment: AppEnvironment
    @Environment(DashboardStore.self) private var dashboard
    @Environment(InputRouter.self) private var inputRouter

    private static let coordinateSpace = "spatial.dashboard"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                dashboardBackdrop

                VStack(spacing: 24) {
                    DashboardClock()

                    HStack(alignment: .top, spacing: 42) {
                        launcherPages
                            .frame(maxWidth: .infinity)

                        widgetPages
                            .frame(width: min(max(proxy.size.width * 0.19, 270), 340))
                    }
                    .frame(maxHeight: .infinity)

                    pageIndicator
                }
                .padding(.top, max(116, proxy.safeAreaInsets.top + 96))
                .padding(.horizontal, max(54, proxy.size.width * 0.055))
                .padding(.bottom, max(30, proxy.safeAreaInsets.bottom + 18))
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(DashboardHitFramePreferenceKey.self) { frames in
                inputRouter.updateDashboardHitFrames(frames, in: proxy.size)
            }
            .onDisappear {
                inputRouter.clearDashboardHitFrames()
            }
        }
    }

    private var dashboardBackdrop: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.orange.opacity(0.12), .clear],
                center: UnitPoint(x: 0.17, y: 0.52),
                startRadius: 10,
                endRadius: 430
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.07), .clear],
                center: UnitPoint(x: 0.78, y: 0.22),
                startRadius: 10,
                endRadius: 520
            )
        }
    }

    private var launcherPages: some View {
        TabView(selection: pageSelection) {
            ForEach(0 ..< dashboard.pageCount, id: \.self) { page in
                let items = dashboard.launcherPage(page)
                Group {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "No shortcuts on this page",
                            systemImage: "square.grid.3x3",
                            description: Text("Add apps and browser bookmarks from the iPhone controller.")
                        )
                        .foregroundStyle(.white.opacity(0.62))
                    } else {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(minimum: 110), spacing: 24),
                                count: 5
                            ),
                            alignment: .center,
                            spacing: 22
                        ) {
                            ForEach(items) { item in
                                DashboardLauncherTile(
                                    item: item,
                                    isHovered: inputRouter.dashboardItem() == item.id
                                ) {
                                    environment.activateDashboardItem(item.id)
                                }
                                .dashboardHitTarget(item.id, in: Self.coordinateSpace)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeOut(duration: 0.22), value: dashboard.selectedPage)
    }

    private var widgetPages: some View {
        TabView(selection: pageSelection) {
            ForEach(0 ..< dashboard.pageCount, id: \.self) { page in
                VStack(spacing: 14) {
                    ForEach(dashboard.widgetPage(page)) { item in
                        DashboardWidgetCard(
                            item: item,
                            isHovered: inputRouter.dashboardItem() == item.id,
                            dashboard: dashboard
                        ) {
                            environment.activateDashboardItem(item.id)
                        }
                        .dashboardHitTarget(item.id, in: Self.coordinateSpace)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeOut(duration: 0.22), value: dashboard.selectedPage)
    }

    private var pageIndicator: some View {
        HStack(spacing: 9) {
            ForEach(0 ..< dashboard.pageCount, id: \.self) { page in
                Button {
                    dashboard.selectedPage = page
                } label: {
                    Capsule()
                        .fill(page == dashboard.selectedPage ? Color.orange : Color.white.opacity(0.23))
                        .frame(width: page == dashboard.selectedPage ? 26 : 8, height: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dashboard page \(page + 1)")
            }
        }
        .frame(height: 18)
    }

    private var pageSelection: Binding<Int> {
        Binding(
            get: { dashboard.selectedPage },
            set: { dashboard.selectedPage = $0 }
        )
    }

}

private struct DashboardClock: View {
    var body: some View {
        PeriodicDateView(every: .seconds(30)) { date in
            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    Text("extend")
                        .foregroundStyle(.orange)
                    Text("reality")
                        .foregroundStyle(.cyan)
                }
                .font(.system(size: 19, weight: .medium, design: .rounded))

                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 72, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.96))

                Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DashboardLauncherTile: View {
    let item: DashboardItem
    let isHovered: Bool
    let action: () -> Void

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
        .animation(.easeOut(duration: 0.16), value: isHovered)
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
        case .bookmark(let bookmark): bookmark.title
        case .widget(let kind): kind.title
        }
    }

    private var accentColor: Color {
        switch item.content {
        case .app(.gallery): .orange
        case .app(.browser): .cyan
        case .app(.youtube): .red
        case .app(.remoteDesktop): .purple
        case .bookmark(let bookmark): bookmark.accent.color
        case .widget: .orange
        }
    }
}

private struct DashboardWidgetCard: View {
    let item: DashboardItem
    let isHovered: Bool
    let dashboard: DashboardStore
    let action: () -> Void

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
        .animation(.easeOut(duration: 0.16), value: isHovered)
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
                Text("Activity summary")
                    .font(.title3.weight(.semibold))
                Text("Health data source not connected")
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
                    Text(isFocusRunning(at: date) ? "Tap to pause" : "25 minute session")
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

private struct DashboardHitFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func dashboardHitTarget(_ id: UUID, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DashboardHitFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
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
