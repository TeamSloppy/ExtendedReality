import Foundation

enum RemoteDisplayLayout: String, CaseIterable, Codable, Identifiable, Sendable {
    static let defaultsKey = "remoteDesktop.displayLayout"

    case single
    case multiple
    case ultrawide

    var id: Self { self }

    var title: String {
        switch self {
        case .single: "One display"
        case .multiple: "Multiple desktops"
        case .ultrawide: "Ultrawide"
        }
    }

    var detail: String {
        switch self {
        case .single: "One Mac display as one spatial surface"
        case .multiple: "Each selected display becomes its own surface"
        case .ultrawide: "Selected displays are joined into one wide canvas"
        }
    }

    var systemImage: String {
        switch self {
        case .single: "display"
        case .multiple: "rectangle.3.group"
        case .ultrawide: "aspectratio"
        }
    }
}
