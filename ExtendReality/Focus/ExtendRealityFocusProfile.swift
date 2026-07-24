import AppIntents
import Foundation

enum ExtendRealityFocusProfile: String, AppEnum, Codable, CaseIterable, Sendable {
    case deepWork
    case collaboration
    case personal
    case rest

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "ExtendReality Profile")

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .deepWork: DisplayRepresentation(title: "Deep Work", image: .init(systemName: "brain.head.profile")),
        .collaboration: DisplayRepresentation(title: "Collaboration", image: .init(systemName: "person.2.fill")),
        .personal: DisplayRepresentation(title: "Personal", image: .init(systemName: "person.fill")),
        .rest: DisplayRepresentation(title: "Rest", image: .init(systemName: "bed.double.fill")),
    ]

    var title: String {
        switch self {
        case .deepWork: "Deep Work"
        case .collaboration: "Collaboration"
        case .personal: "Personal"
        case .rest: "Rest"
        }
    }

    var systemImage: String {
        switch self {
        case .deepWork: "brain.head.profile"
        case .collaboration: "person.2.fill"
        case .personal: "person.fill"
        case .rest: "bed.double.fill"
        }
    }
}

struct ExtendRealityFocusSelection: Codable, Equatable, Sendable {
    let profile: ExtendRealityFocusProfile?
    let updatedAt: Date
}

enum ExtendRealityFocusStorage {
    static let appGroupIdentifier = "group.com.vladprusakov.ExtendReality"
    static let selectionKey = "focusFilter.selection.v1"

    static func load(defaults: UserDefaults? = nil) -> ExtendRealityFocusSelection? {
        let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier)
        guard let data = defaults?.data(forKey: selectionKey) else { return nil }
        return try? JSONDecoder().decode(ExtendRealityFocusSelection.self, from: data)
    }

    static func save(
        _ selection: ExtendRealityFocusSelection,
        defaults: UserDefaults? = nil
    ) {
        let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier)
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults?.set(data, forKey: selectionKey)
    }
}
