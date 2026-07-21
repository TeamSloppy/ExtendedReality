import SwiftUI

struct TabbedBrowserSurfaceView: View {
    @Bindable var browser: BrowserWindowSession

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                tabStrip
                    .frame(height: BrowserChromeLayout.tabBarHeight)
                navigationBar
                    .frame(height: BrowserChromeLayout.navigationBarHeight)
                activeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
            .onAppear {
                browser.updateSpatialSurfaceSize(proxy.size)
            }
            .onChange(of: proxy.size) { _, size in
                browser.updateSpatialSurfaceSize(size)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(browser.tabs) { tab in
                HStack(spacing: 6) {
                    Image(systemName: tab.session.isLoading ? "circle.dotted" : "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(tab.displayTitle)
                        .font(.caption.weight(tab.id == browser.activeTabID ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 18, height: 18)
                        .opacity(browser.tabs.count > 1 ? 0.78 : 0.3)
                }
                .foregroundStyle(.white.opacity(tab.id == browser.activeTabID ? 0.96 : 0.68))
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tabBackground(for: tab.id))
                .overlay(alignment: .bottom) {
                    if tab.id == browser.activeTabID {
                        Rectangle()
                            .fill(.cyan)
                            .frame(height: 2)
                    }
                }
            }

            Text(browser.tabCountLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: BrowserChromeLayout.tabCountWidth)
                .frame(maxHeight: .infinity)

            Image(systemName: "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(browser.canCreateTab ? .white : .secondary)
                .frame(width: BrowserChromeLayout.newTabWidth)
                .frame(maxHeight: .infinity)
                .background(chromeBackground(for: .newTab))
                .accessibilityLabel("New tab")
        }
        .background(Color(white: 0.08))
        .overlay(alignment: .bottom) {
            Divider().overlay(.white.opacity(0.1))
        }
    }

    private var navigationBar: some View {
        let session = browser.activeSession
        return HStack(spacing: 0) {
            navigationIcon(
                "chevron.backward",
                width: BrowserChromeLayout.navigationButtonWidth,
                isEnabled: session.canGoBack,
                target: .back,
                label: "Back"
            )
            navigationIcon(
                "chevron.forward",
                width: BrowserChromeLayout.navigationButtonWidth,
                isEnabled: session.canGoForward,
                target: .forward,
                label: "Forward"
            )

            HStack(spacing: 8) {
                Image(systemName: session.address.isEmpty ? "magnifyingglass" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.address.isEmpty ? "Search or enter address on iPhone" : session.address)
                    .font(.caption)
                    .foregroundStyle(session.address.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: 34)
            .background(
                browser.hoveredChromeTarget == .address
                    ? Color.white.opacity(0.16)
                    : Color.white.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityLabel("Address")
            .accessibilityValue(session.address)

            navigationIcon(
                "arrow.clockwise",
                width: BrowserChromeLayout.reloadButtonWidth,
                isEnabled: true,
                target: .reload,
                label: "Reload"
            )
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().overlay(.white.opacity(0.1))
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        let tab = browser.activeTab
        if tab.session.hasLoadedRequest {
            ZStack {
                BrowserSurfaceView(session: tab.session)
                    .id(tab.id)
                if let error = tab.session.lastErrorMessage {
                    ContentUnavailableView {
                        Label("Page unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
        } else {
            ContentUnavailableView {
                Label("New Tab", systemImage: "globe")
            } description: {
                Text("Enter an address or search on iPhone.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.08), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func tabBackground(for id: UUID) -> Color {
        if browser.hoveredChromeTarget == .closeTab(id) || browser.hoveredChromeTarget == .tab(id) {
            return .white.opacity(0.15)
        }
        return id == browser.activeTabID ? .white.opacity(0.11) : .clear
    }

    private func chromeBackground(for target: BrowserChromeTarget) -> Color {
        browser.hoveredChromeTarget == target ? .white.opacity(0.15) : .clear
    }

    private func navigationIcon(
        _ systemImage: String,
        width: CGFloat,
        isEnabled: Bool,
        target: BrowserChromeTarget,
        label: String
    ) -> some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? .white.opacity(0.9) : .secondary.opacity(0.5))
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(chromeBackground(for: target))
            .accessibilityLabel(label)
    }
}

#if DEBUG
#Preview("Tabbed Browser Surface") {
    TabbedBrowserSurfaceView(
        browser: BrowserWindowSession(initialURL: "", loadsContent: false)
    )
    .frame(width: 960, height: 540)
    .preferredColorScheme(.dark)
}
#endif
