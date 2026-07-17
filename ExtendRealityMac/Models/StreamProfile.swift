import CoreGraphics
import Foundation

enum StreamLayout: String, CaseIterable, Codable, Identifiable, Sendable {
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

struct RemoteStreamEndpoint: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
}

struct RemoteStreamSession: Codable, Equatable, Sendable {
    let version: Int
    let layout: StreamLayout
    let streams: [RemoteStreamEndpoint]
}

struct RemoteStreamAPIError: Codable, Equatable, Sendable {
    let error: String
}

struct CaptureDisplay: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int

    var resolutionDescription: String {
        "\(width) × \(height)"
    }
}

enum CaptureState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case capturing
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Not configured"
        case .loading: "Loading displays…"
        case .ready: "Ready"
        case .capturing: "Live"
        case .failed: "Needs attention"
        }
    }
}

enum UltrawideLayout {
    static let maximumCanvasSize = CGSize(width: 5_120, height: 1_440)

    static func canvasSize(for sourceSizes: [CGSize]) -> CGSize {
        guard !sourceSizes.isEmpty else { return .zero }

        let totalWidth = sourceSizes.reduce(0) { $0 + max($1.width, 1) }
        let maximumHeight = sourceSizes.reduce(1) { max($0, $1.height) }
        let scale = min(
            maximumCanvasSize.width / totalWidth,
            maximumCanvasSize.height / maximumHeight,
            1
        )

        return CGSize(
            width: max(2, floor(totalWidth * scale / 2) * 2),
            height: max(2, floor(maximumHeight * scale / 2) * 2)
        )
    }
}
