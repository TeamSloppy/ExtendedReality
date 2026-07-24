import Foundation

enum DashboardWidgetKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case calendar
    case health
    case focus
    case translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .health: "Health"
        case .focus: "Focus"
        case .translation: "Live Translation"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .health: "heart.fill"
        case .focus: "timer"
        case .translation: "captions.bubble.fill"
        }
    }
}

enum DashboardScenario: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case work
    case personal
    case travel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: "Work"
        case .personal: "Personal"
        case .travel: "Travel"
        }
    }

    var systemImage: String {
        switch self {
        case .work: "briefcase.fill"
        case .personal: "person.fill"
        case .travel: "airplane"
        }
    }
}
