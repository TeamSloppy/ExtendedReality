import CoreGraphics
import Foundation

enum WindowKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case browser
    case gallery
    case youtube
    case remoteDesktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "Browser"
        case .gallery: "Gallery"
        case .youtube: "YouTube"
        case .remoteDesktop: "Mac"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: "safari"
        case .gallery: "photo.on.rectangle.angled"
        case .youtube: "play.rectangle.fill"
        case .remoteDesktop: "desktopcomputer"
        }
    }
}

enum WindowSource: Codable, Equatable, Sendable {
    case browser(url: String)
    case pwa(PWAInstallation, displayMode: PWADisplayMode)
    case gallery
    case youtube(videoID: String?)
    case remoteDesktop(host: String?)

    var kind: WindowKind {
        switch self {
        case .browser: .browser
        case .pwa: .browser
        case .gallery: .gallery
        case .youtube: .youtube
        case .remoteDesktop: .remoteDesktop
        }
    }

    static func initial(for kind: WindowKind) -> WindowSource {
        switch kind {
        case .browser: .browser(url: "https://www.apple.com")
        case .gallery: .gallery
        case .youtube: .youtube(videoID: nil)
        case .remoteDesktop: .remoteDesktop(host: nil)
        }
    }
}

enum WindowLayoutOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    var toggled: Self {
        self == .horizontal ? .vertical : .horizontal
    }
}

struct WindowTransform3DoF: Codable, Equatable, Sendable {
    static let virtualDistanceRange = 0.65 ... 1.8

    var yaw: Double
    var pitch: Double
    var virtualDistance: Double
    var width: Double
    var height: Double

    static let centered = WindowTransform3DoF(
        yaw: 0,
        pitch: 0,
        virtualDistance: 1,
        width: 0.72,
        height: 0.68
    )

    static let macStream = WindowTransform3DoF(
        yaw: 0,
        pitch: 0,
        virtualDistance: 1,
        width: 0.90,
        height: 0.80
    )

    mutating func clamp() {
        yaw = yaw.clamped(to: -42 ... 42)
        pitch = pitch.clamped(to: -24 ... 24)
        virtualDistance = virtualDistance.clamped(to: Self.virtualDistanceRange)
        width = width.isFinite ? max(width, 0.35) : Self.centered.width
        height = height.isFinite ? max(height, 0.30) : Self.centered.height
    }
}

struct SpatialAppTransform3DoF: Codable, Equatable, Sendable {
    static let scaleRange = 0.35 ... 4.0

    var yaw: Double
    var pitch: Double
    var virtualDistance: Double
    var scale: Double

    static let centered = SpatialAppTransform3DoF(
        yaw: 0,
        pitch: 0,
        virtualDistance: 1,
        scale: 1
    )

    mutating func clamp() {
        yaw = yaw.clamped(to: -42 ... 42)
        pitch = pitch.clamped(to: -24 ... 24)
        virtualDistance = virtualDistance.clamped(to: WindowTransform3DoF.virtualDistanceRange)
        scale = scale.isFinite ? scale.clamped(to: Self.scaleRange) : 1
    }
}

struct SpatialPanelID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    static let primary: Self = "primary"
}

struct SpatialPanelPlacement: Codable, Equatable, Sendable {
    var yaw: Double
    var pitch: Double
    var depth: Double
    var width: Double
    var height: Double
    var layer: Int

    init(
        yaw: Double = 0,
        pitch: Double = 0,
        depth: Double = 0,
        width: Double,
        height: Double,
        layer: Int = 0
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.depth = depth
        self.width = width
        self.height = height
        self.layer = layer
    }

    func validated() throws -> Self {
        guard yaw.isFinite, (-42 ... 42).contains(yaw),
              pitch.isFinite, (-24 ... 24).contains(pitch),
              depth.isFinite, (-0.5 ... 0.5).contains(depth),
              width.isFinite, (0.15 ... 1.5).contains(width),
              height.isFinite, (0.10 ... 1.2).contains(height),
              (-16 ... 16).contains(layer) else {
            throw SpatialWindowError.invalidPlacement
        }
        return self
    }
}

enum SpatialPanelContent: Codable, Equatable, Sendable {
    case primary
    case native(String)
    case web(URL)
}

struct SpatialPanelDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: SpatialPanelID
    var accessibilityLabel: String
    var placement: SpatialPanelPlacement
    var content: SpatialPanelContent

    init(
        id: SpatialPanelID,
        accessibilityLabel: String,
        placement: SpatialPanelPlacement,
        content: SpatialPanelContent
    ) {
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.placement = placement
        self.content = content
    }
}

struct SpatialAppLayout: Codable, Equatable, Sendable {
    static let maximumPanelCount = 8

    var primaryPanelID: SpatialPanelID
    var panels: [SpatialPanelDescriptor]

    init(primaryPanelID: SpatialPanelID = .primary, panels: [SpatialPanelDescriptor]) {
        self.primaryPanelID = primaryPanelID
        self.panels = panels
    }

    func validated(
        allowedOrigins: Set<PWAOrigin>? = nil,
        permitsPrevalidatedWebContent: Bool = false
    ) throws -> Self {
        guard !panels.isEmpty, panels.count <= Self.maximumPanelCount else {
            throw SpatialWindowError.invalidPanelCount
        }
        let ids = Set(panels.map(\.id))
        guard ids.count == panels.count, ids.contains(primaryPanelID) else {
            throw SpatialWindowError.invalidPanelIdentifier
        }
        for panel in panels {
            let rawID = panel.id.rawValue
            guard rawID.count <= 64,
                  rawID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
                  !panel.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpatialWindowError.invalidPanelIdentifier
            }
            _ = try panel.placement.validated()
            if case .web(let url) = panel.content {
                if permitsPrevalidatedWebContent { continue }
                guard let allowedOrigins,
                      let origin = try? PWAOrigin(url: url),
                      allowedOrigins.contains(origin) else {
                    throw SpatialWindowError.disallowedURL
                }
            }
        }
        return self
    }
}

enum SpatialWindowError: LocalizedError, Equatable {
    case invalidPanelCount
    case invalidPanelIdentifier
    case invalidPlacement
    case disallowedURL
    case permissionDenied
    case missingWindow

    var errorDescription: String? {
        switch self {
        case .invalidPanelCount: "A spatial app must contain between one and eight panels."
        case .invalidPanelIdentifier: "Spatial panel identifiers must be unique and valid."
        case .invalidPlacement: "The spatial panel placement is outside the supported range."
        case .disallowedURL: "The panel URL is outside the app's allowed origins."
        case .permissionDenied: "The app is not allowed to create spatial panels."
        case .missingWindow: "The owning workspace window no longer exists."
        }
    }
}

struct WorkspaceWindow: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var source: WindowSource
    var appTransform: SpatialAppTransform3DoF
    var zIndex: Int
    var isMinimized: Bool
    var contentAspectRatio: Double?
    var layoutOrientation: WindowLayoutOrientation?

    var transform: WindowTransform3DoF {
        get {
            let nominal = nominalSinglePanelSize
            return WindowTransform3DoF(
                yaw: appTransform.yaw,
                pitch: appTransform.pitch,
                virtualDistance: appTransform.virtualDistance,
                width: max(nominal.width * appTransform.scale, 0.35),
                height: max(nominal.height * appTransform.scale, 0.30)
            )
        }
        set {
            let nominal = nominalSinglePanelSize
            appTransform = SpatialAppTransform3DoF(
                yaw: newValue.yaw,
                pitch: newValue.pitch,
                virtualDistance: newValue.virtualDistance,
                scale: newValue.width / max(nominal.width, 0.001)
            )
            appTransform.clamp()
        }
    }

    var kind: WindowKind { source.kind }

    var systemImage: String {
        switch source {
        case .pwa(_, displayMode: .widget): "rectangle.3.group.fill"
        case .pwa: "app.fill"
        default: kind.systemImage
        }
    }

    var effectiveLayoutOrientation: WindowLayoutOrientation {
        layoutOrientation ?? .horizontal
    }

    var layoutContentAspectRatio: Double {
        let horizontalAspectRatio = contentAspectRatio ?? (16.0 / 10.0)
        switch effectiveLayoutOrientation {
        case .horizontal:
            return horizontalAspectRatio
        case .vertical:
            return 1 / horizontalAspectRatio
        }
    }

    private var nominalSinglePanelSize: (width: Double, height: Double) {
        switch source {
        case .remoteDesktop:
            (WindowTransform3DoF.macStream.width, WindowTransform3DoF.macStream.height)
        default:
            (WindowTransform3DoF.centered.width, WindowTransform3DoF.centered.height)
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        source: WindowSource,
        transform: WindowTransform3DoF = .centered,
        zIndex: Int = 0,
        isMinimized: Bool = false,
        contentAspectRatio: Double? = nil,
        layoutOrientation: WindowLayoutOrientation? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        let nominalWidth: Double
        switch source {
        case .remoteDesktop:
            nominalWidth = WindowTransform3DoF.macStream.width
        default:
            nominalWidth = WindowTransform3DoF.centered.width
        }
        appTransform = SpatialAppTransform3DoF(
            yaw: transform.yaw,
            pitch: transform.pitch,
            virtualDistance: transform.virtualDistance,
            scale: transform.width / nominalWidth
        )
        appTransform.clamp()
        self.zIndex = zIndex
        self.isMinimized = isMinimized
        self.contentAspectRatio = contentAspectRatio
        self.layoutOrientation = layoutOrientation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case source
        case appTransform
        case transform
        case zIndex
        case isMinimized
        case contentAspectRatio
        case layoutOrientation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        source = try container.decode(WindowSource.self, forKey: .source)
        zIndex = try container.decode(Int.self, forKey: .zIndex)
        isMinimized = try container.decode(Bool.self, forKey: .isMinimized)
        contentAspectRatio = try container.decodeIfPresent(Double.self, forKey: .contentAspectRatio)
        layoutOrientation = try container.decodeIfPresent(WindowLayoutOrientation.self, forKey: .layoutOrientation)

        if let decoded = try container.decodeIfPresent(SpatialAppTransform3DoF.self, forKey: .appTransform) {
            appTransform = decoded
        } else {
            let legacy = try container.decode(WindowTransform3DoF.self, forKey: .transform)
            let nominalWidth = source.kind == .remoteDesktop
                ? WindowTransform3DoF.macStream.width
                : WindowTransform3DoF.centered.width
            appTransform = SpatialAppTransform3DoF(
                yaw: legacy.yaw,
                pitch: legacy.pitch,
                virtualDistance: legacy.virtualDistance,
                scale: legacy.width / nominalWidth
            )
        }
        appTransform.clamp()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(source, forKey: .source)
        try container.encode(appTransform, forKey: .appTransform)
        try container.encode(zIndex, forKey: .zIndex)
        try container.encode(isMinimized, forKey: .isMinimized)
        try container.encodeIfPresent(contentAspectRatio, forKey: .contentAspectRatio)
        try container.encodeIfPresent(layoutOrientation, forKey: .layoutOrientation)
    }
}

enum ControlMode: String, CaseIterable, Identifiable, Sendable {
    case pointer
    case arrange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pointer: "Cursor"
        case .arrange: "Arrange"
        }
    }

    var systemImage: String {
        switch self {
        case .pointer: "cursorarrow.motionlines"
        case .arrange: "move.3d"
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
