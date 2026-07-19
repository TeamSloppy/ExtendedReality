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
    let width: Int
    let height: Int
}

struct RemoteStreamSession: Codable, Equatable, Sendable {
    let version: Int
    let layout: StreamLayout
    let streams: [RemoteStreamEndpoint]
    let cursorURL: URL?

    init(
        version: Int,
        layout: StreamLayout,
        streams: [RemoteStreamEndpoint],
        cursorURL: URL? = nil
    ) {
        self.version = version
        self.layout = layout
        self.streams = streams
        self.cursorURL = cursorURL
    }
}

struct RemoteCursorPosition: Codable, Equatable, Sendable {
    let version: Int
    let streamID: String?
    let x: Double?
    let y: Double?
    let visible: Bool

    static let hidden = RemoteCursorPosition(
        version: 1,
        streamID: nil,
        x: nil,
        y: nil,
        visible: false
    )
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

enum StreamGeometry {
    static let maximumCaptureDimension = 2_560.0

    static func captureSize(width: Int, height: Int) -> CGSize {
        let largestDimension = Double(max(width, height))
        let scale = min(maximumCaptureDimension / max(largestDimension, 1), 1)
        return CGSize(
            width: max(2, Int(Double(width) * scale) / 2 * 2),
            height: max(2, Int(Double(height) * scale) / 2 * 2)
        )
    }

    static func primarySize(layout: StreamLayout, displays: [CaptureDisplay]) -> CGSize {
        let captureSizes = displays.map { captureSize(width: $0.width, height: $0.height) }
        if layout == .ultrawide {
            return UltrawideLayout.canvasSize(for: captureSizes)
        }
        return captureSizes.first ?? .zero
    }
}

enum CursorStreamGeometry {
    static func position(
        cursor: CGPoint,
        layout: StreamLayout,
        displays: [CaptureDisplay],
        displayBounds: [CGDirectDisplayID: CGRect]
    ) -> RemoteCursorPosition {
        guard let display = displays.first(where: { display in
            displayBounds[display.id]?.contains(cursor) == true
        }), let bounds = displayBounds[display.id], bounds.width > 0, bounds.height > 0 else {
            return .hidden
        }

        let localPosition = CGPoint(
            x: ((cursor.x - bounds.minX) / bounds.width).clamped(to: 0 ... 1),
            y: ((cursor.y - bounds.minY) / bounds.height).clamped(to: 0 ... 1)
        )

        switch layout {
        case .single:
            guard display.id == displays.first?.id else { return .hidden }
            return visiblePosition(streamID: "primary", position: localPosition)
        case .multiple:
            return visiblePosition(streamID: String(display.id), position: localPosition)
        case .ultrawide:
            guard let position = ultrawidePosition(
                localPosition,
                on: display.id,
                displays: displays
            ) else { return .hidden }
            return visiblePosition(streamID: "primary", position: position)
        }
    }

    private static func ultrawidePosition(
        _ localPosition: CGPoint,
        on displayID: CGDirectDisplayID,
        displays: [CaptureDisplay]
    ) -> CGPoint? {
        let sizes = displays.map { StreamGeometry.captureSize(width: $0.width, height: $0.height) }
        let canvasSize = UltrawideLayout.canvasSize(for: sizes)
        let sourceWidth = sizes.reduce(0) { $0 + $1.width }
        guard canvasSize.width > 0, canvasSize.height > 0, sourceWidth > 0,
              let index = displays.firstIndex(where: { $0.id == displayID }) else { return nil }

        let scale = canvasSize.width / sourceWidth
        let leadingWidth = sizes.prefix(index).reduce(0) { $0 + $1.width } * scale
        let displaySize = sizes[index]
        let renderedWidth = displaySize.width * scale
        let renderedHeight = displaySize.height * scale
        let verticalInset = (canvasSize.height - renderedHeight) / 2

        return CGPoint(
            x: (leadingWidth + localPosition.x * renderedWidth) / canvasSize.width,
            y: (verticalInset + localPosition.y * renderedHeight) / canvasSize.height
        )
    }

    private static func visiblePosition(
        streamID: String,
        position: CGPoint
    ) -> RemoteCursorPosition {
        RemoteCursorPosition(
            version: 1,
            streamID: streamID,
            x: Double(position.x),
            y: Double(position.y),
            visible: true
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
