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
    var placement: DashboardPlacement

    init(
        id: UUID = UUID(),
        content: DashboardItemContent,
        placement: DashboardPlacement = .unplaced
    ) {
        self.id = id
        self.content = content
        self.placement = placement
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case placement
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(DashboardItemContent.self, forKey: .content)
        placement = try container.decodeIfPresent(
            DashboardPlacement.self,
            forKey: .placement
        ) ?? .unplaced
    }
}

struct DashboardPlacement: Codable, Equatable, Sendable {
    static let scaleRange = 0.75 ... 1.5
    static let unplaced = DashboardPlacement(x: 0.5, y: 0.5, scale: 1, zIndex: -1)

    var x: Double
    var y: Double
    var scale: Double
    var zIndex: Int

    var isPlaced: Bool {
        zIndex >= 0 && x.isFinite && y.isFinite && scale.isFinite
    }

    mutating func clamp(for content: DashboardItemContent) {
        scale = scale.isFinite ? scale.clamped(to: Self.scaleRange) : 1
        let baseSize = DashboardLayout.baseSize(for: content)
        let halfWidth = Double(baseSize.width) * scale / (DashboardLayout.referenceWidth * 2)
        let halfHeight = Double(baseSize.height) * scale / (DashboardLayout.referenceHeight * 2)
        x = (x.isFinite ? x : 0.5).clamped(to: halfWidth ... 1 - halfWidth)
        y = (y.isFinite ? y : 0.5).clamped(
            to: DashboardLayout.reservedTopFraction + halfHeight ... 1 - halfHeight
        )
        zIndex = max(0, zIndex)
    }
}

enum DashboardLayout {
    static let referenceWidth = 1_920.0
    static let referenceHeight = 1_080.0
    static let reservedTopFraction = 0.15

    static func baseSize(for content: DashboardItemContent) -> CGSize {
        switch content {
        case .app, .pwa, .bookmark:
            CGSize(width: 148, height: 170)
        case .widget:
            CGSize(width: 360, height: 161)
        }
    }

    static func defaultPlacement(
        for content: DashboardItemContent,
        itemIndex: Int,
        launcherIndex: Int,
        widgetIndex: Int
    ) -> DashboardPlacement {
        switch content {
        case .widget(let kind):
            let center: (Double, Double)
            switch kind {
            case .health: center = (0.18, 0.34)
            case .calendar: center = (0.82, 0.34)
            case .focus: center = (0.50, 0.52)
            }
            return DashboardPlacement(x: center.0, y: center.1, scale: 1, zIndex: itemIndex)
        case .app, .pwa, .bookmark:
            let column = launcherIndex % 8
            let row = launcherIndex / 8
            return DashboardPlacement(
                x: 0.115 + Double(column) * 0.11,
                y: 0.82 - Double(row) * 0.17,
                scale: 1,
                zIndex: itemIndex
            )
        }
    }
}

struct DashboardItemPresentation: Identifiable, Equatable, Sendable {
    let item: DashboardItem
    let center: CGPoint
    let size: CGSize
    let rotationDegrees: Double

    var id: UUID { item.id }
}

enum DashboardProjection {
    static func stabilizationRotation(
        for headPose: HeadPose,
        isTracking: Bool
    ) -> Double {
        isTracking ? -headPose.roll : 0
    }

    static func presentation(
        for item: DashboardItem,
        in canvasSize: CGSize,
        rotationDegrees: Double
    ) -> DashboardItemPresentation {
        let referenceScale = min(
            canvasSize.width / DashboardLayout.referenceWidth,
            canvasSize.height / DashboardLayout.referenceHeight
        )
        let baseSize = DashboardLayout.baseSize(for: item.content)
        let size = CGSize(
            width: baseSize.width * item.placement.scale * referenceScale,
            height: baseSize.height * item.placement.scale * referenceScale
        )
        let unrotatedCenter = CGPoint(
            x: item.placement.x * canvasSize.width,
            y: item.placement.y * canvasSize.height
        )
        let center = rotate(
            unrotatedCenter,
            around: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
            degrees: rotationDegrees
        )
        return DashboardItemPresentation(
            item: item,
            center: center,
            size: size,
            rotationDegrees: rotationDegrees
        )
    }

    private static func rotate(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let translatedX = Double(point.x - center.x)
        let translatedY = Double(point.y - center.y)
        return CGPoint(
            x: center.x + CGFloat(translatedX * cos(radians) - translatedY * sin(radians)),
            y: center.y + CGFloat(translatedX * sin(radians) + translatedY * cos(radians))
        )
    }
}

@MainActor
@Observable
final class DashboardStore {
    private(set) var items: [DashboardItem]
    private(set) var selectedItemID: UUID?
    private(set) var focusEndDate: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let mapsLauncherMigrationKey: String
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "dashboard.items.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        mapsLauncherMigrationKey = "\(storageKey).mapsLauncher.v1"
        if let data = defaults.data(forKey: storageKey),
           let restored = try? decoder.decode([DashboardItem].self, from: data) {
            items = restored
        } else {
            items = Self.defaultItems
        }
        let addedMapsLauncher = addMapsLauncherIfNeeded()
        if normalizePlacements() || addedMapsLauncher {
            save()
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

    func item(id: UUID) -> DashboardItem? {
        items.first(where: { $0.id == id })
    }

    func addApp(_ kind: WindowKind) {
        guard !items.contains(where: { $0.content == .app(kind) }) else { return }
        items.append(DashboardItem(content: .app(kind)))
        _ = normalizePlacements()
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
        _ = normalizePlacements()
        save()
    }

    func removePWA(_ appID: String) {
        items.removeAll(where: {
            if case .pwa(let installation) = $0.content { return installation.id == appID }
            return false
        })
        if selectedItemID.map({ selectedID in !items.contains(where: { $0.id == selectedID }) }) == true {
            selectedItemID = nil
        }
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
        _ = normalizePlacements()
        save()
        return true
    }

    func addWidget(_ kind: DashboardWidgetKind) {
        guard !items.contains(where: { $0.content == .widget(kind) }) else { return }
        items.append(DashboardItem(content: .widget(kind)))
        _ = normalizePlacements()
        save()
    }

    func remove(at offsets: IndexSet) {
        let removedIDs = Set(offsets.compactMap { items.indices.contains($0) ? items[$0].id : nil })
        items.remove(atOffsets: offsets)
        if let selectedItemID, removedIDs.contains(selectedItemID) {
            self.selectedItemID = nil
        }
        save()
    }

    func beginArranging(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        selectedItemID = id
        let nextZ = (items.map(\.placement.zIndex).max() ?? 0) + 1
        items[index].placement.zIndex = nextZ
    }

    func moveSelected(normalizedDelta: CGVector) {
        guard normalizedDelta.dx.isFinite,
              normalizedDelta.dy.isFinite,
              let selectedItemID,
              let index = items.firstIndex(where: { $0.id == selectedItemID }) else { return }
        items[index].placement.x += normalizedDelta.dx
        items[index].placement.y += normalizedDelta.dy
        items[index].placement.clamp(for: items[index].content)
    }

    func scaleSelected(by magnificationDelta: CGFloat) {
        guard magnificationDelta.isFinite,
              magnificationDelta > 0,
              let selectedItemID,
              let index = items.firstIndex(where: { $0.id == selectedItemID }) else { return }
        items[index].placement.scale *= Double(magnificationDelta)
        items[index].placement.clamp(for: items[index].content)
    }

    func endArranging() {
        guard selectedItemID != nil else { return }
        save()
    }

    func clearSelection() {
        selectedItemID = nil
    }

    func reset() {
        items = Self.defaultItems
        _ = normalizePlacements()
        selectedItemID = nil
        save()
    }

    func resetLayout() {
        for index in items.indices {
            items[index].placement = .unplaced
        }
        _ = normalizePlacements()
        selectedItemID = nil
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

    private func save() {
        guard let data = try? encoder.encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }

    @discardableResult
    private func addMapsLauncherIfNeeded() -> Bool {
        guard !defaults.bool(forKey: mapsLauncherMigrationKey) else { return false }
        defaults.set(true, forKey: mapsLauncherMigrationKey)
        guard !items.contains(where: { $0.content == .app(.maps) }) else { return false }
        items.append(DashboardItem(content: .app(.maps)))
        return true
    }

    @discardableResult
    private func normalizePlacements() -> Bool {
        var changed = false
        var launcherIndex = 0
        var widgetIndex = 0
        for index in items.indices {
            if !items[index].placement.isPlaced {
                items[index].placement = DashboardLayout.defaultPlacement(
                    for: items[index].content,
                    itemIndex: index,
                    launcherIndex: launcherIndex,
                    widgetIndex: widgetIndex
                )
                changed = true
            }
            let previous = items[index].placement
            items[index].placement.clamp(for: items[index].content)
            changed = changed || previous != items[index].placement
            switch items[index].content {
            case .widget:
                widgetIndex += 1
            case .app, .pwa, .bookmark:
                launcherIndex += 1
            }
        }
        return changed
    }

    private static var defaultItems: [DashboardItem] {
        [
            DashboardItem(content: .app(.gallery)),
            DashboardItem(content: .app(.browser)),
            DashboardItem(content: .app(.maps)),
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
