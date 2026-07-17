import Foundation
import Observation
import SwiftUI

enum DashboardAccent: String, Codable, CaseIterable, Sendable {
    case orange
    case cyan
    case red
    case purple
    case blue
    case green
    case pink
}

enum DashboardWidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case calendar
    case health
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .health: "Health"
        case .focus: "Focus"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .health: "heart.fill"
        case .focus: "timer"
        }
    }
}

struct DashboardBookmark: Codable, Equatable, Sendable {
    var title: String
    var url: String
    var monogram: String
    var accent: DashboardAccent
}

enum DashboardItemContent: Codable, Equatable, Sendable {
    case app(WindowKind)
    case pwa(PWAInstallation)
    case bookmark(DashboardBookmark)
    case widget(DashboardWidgetKind)
}

struct DashboardItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: DashboardItemContent

    init(id: UUID = UUID(), content: DashboardItemContent) {
        self.id = id
        self.content = content
    }
}

enum DashboardLayout {
    static let launchersPerPage = 10
    static let widgetsPerPage = 3
}

@MainActor
@Observable
final class DashboardStore {
    private(set) var items: [DashboardItem]
    var selectedPage = 0
    private(set) var focusEndDate: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var pageScrollAccumulator: CGFloat = 0
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "dashboard.items.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let restored = try? decoder.decode([DashboardItem].self, from: data) {
            items = restored
        } else {
            items = Self.defaultItems
        }
    }

    var launchers: [DashboardItem] {
        items.filter {
            switch $0.content {
            case .app, .pwa, .bookmark: true
            case .widget: false
            }
        }
    }

    var widgets: [DashboardItem] {
        items.filter {
            if case .widget = $0.content { return true }
            return false
        }
    }

    var pageCount: Int {
        let launcherPages = Int(ceil(Double(launchers.count) / Double(DashboardLayout.launchersPerPage)))
        let widgetPages = Int(ceil(Double(widgets.count) / Double(DashboardLayout.widgetsPerPage)))
        return max(1, max(launcherPages, widgetPages))
    }

    func launcherPage(_ page: Int) -> [DashboardItem] {
        let start = page * DashboardLayout.launchersPerPage
        guard start < launchers.count else { return [] }
        return Array(launchers[start ..< min(start + DashboardLayout.launchersPerPage, launchers.count)])
    }

    func widgetPage(_ page: Int) -> [DashboardItem] {
        let start = page * DashboardLayout.widgetsPerPage
        guard start < widgets.count else { return [] }
        return Array(widgets[start ..< min(start + DashboardLayout.widgetsPerPage, widgets.count)])
    }

    func item(id: UUID) -> DashboardItem? {
        items.first(where: { $0.id == id })
    }

    func addApp(_ kind: WindowKind) {
        guard !items.contains(where: { $0.content == .app(kind) }) else { return }
        items.append(DashboardItem(content: .app(kind)))
        save()
    }

    func addPWA(_ installation: PWAInstallation) {
        if let index = items.firstIndex(where: {
            if case .pwa(let existing) = $0.content { return existing.id == installation.id }
            return false
        }) {
            items[index].content = .pwa(installation)
        } else {
            items.append(DashboardItem(content: .pwa(installation)))
        }
        save()
    }

    func removePWA(_ appID: String) {
        items.removeAll(where: {
            if case .pwa(let installation) = $0.content { return installation.id == appID }
            return false
        })
        clampSelectedPage()
        save()
    }

    @discardableResult
    func addBookmark(
        title: String,
        url rawURL: String,
        accent: DashboardAccent = .blue
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return false }
        let resolvedURL = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        guard let url = URL(string: resolvedURL), url.host != nil else { return false }

        let monogram = String(trimmedTitle.prefix(1)).uppercased()
        items.append(
            DashboardItem(
                content: .bookmark(
                    DashboardBookmark(
                        title: trimmedTitle,
                        url: resolvedURL,
                        monogram: monogram,
                        accent: accent
                    )
                )
            )
        )
        save()
        return true
    }

    func addWidget(_ kind: DashboardWidgetKind) {
        guard !items.contains(where: { $0.content == .widget(kind) }) else { return }
        items.append(DashboardItem(content: .widget(kind)))
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        clampSelectedPage()
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func reset() {
        items = Self.defaultItems
        selectedPage = 0
        save()
    }

    func toggleFocusTimer() {
        if let focusEndDate, focusEndDate > .now {
            self.focusEndDate = nil
        } else {
            focusEndDate = .now.addingTimeInterval(25 * 60)
        }
    }

    func resetFocusTimer() {
        focusEndDate = nil
    }

    func focusTimeRemaining(at date: Date) -> TimeInterval {
        max(0, focusEndDate?.timeIntervalSince(date) ?? 25 * 60)
    }

    var isFocusRunning: Bool {
        guard let focusEndDate else { return false }
        return focusEndDate > .now
    }

    func consumePageScroll(_ delta: CGFloat) {
        pageScrollAccumulator += delta
        guard abs(pageScrollAccumulator) >= 0.12 else { return }
        let direction = pageScrollAccumulator > 0 ? 1 : -1
        selectedPage = (selectedPage + direction).clamped(to: 0 ... max(pageCount - 1, 0))
        pageScrollAccumulator = 0
    }

    private func clampSelectedPage() {
        selectedPage = selectedPage.clamped(to: 0 ... max(pageCount - 1, 0))
    }

    private func save() {
        guard let data = try? encoder.encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static var defaultItems: [DashboardItem] {
        [
            DashboardItem(content: .app(.gallery)),
            DashboardItem(content: .app(.browser)),
            DashboardItem(content: .app(.youtube)),
            DashboardItem(content: .app(.remoteDesktop)),
            DashboardItem(
                content: .bookmark(
                    DashboardBookmark(title: "Netflix", url: "https://www.netflix.com", monogram: "N", accent: .red)
                )
            ),
            DashboardItem(
                content: .bookmark(
                    DashboardBookmark(title: "Disney+", url: "https://www.disneyplus.com", monogram: "D+", accent: .blue)
                )
            ),
            DashboardItem(
                content: .bookmark(
                    DashboardBookmark(title: "Prime Video", url: "https://www.primevideo.com", monogram: "P", accent: .cyan)
                )
            ),
            DashboardItem(
                content: .bookmark(
                    DashboardBookmark(title: "Twitch", url: "https://www.twitch.tv", monogram: "T", accent: .purple)
                )
            ),
            DashboardItem(content: .widget(.calendar)),
            DashboardItem(content: .widget(.health)),
            DashboardItem(content: .widget(.focus)),
        ]
    }
}
