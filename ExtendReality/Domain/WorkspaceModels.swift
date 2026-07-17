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

    mutating func clamp() {
        yaw = yaw.clamped(to: -42 ... 42)
        pitch = pitch.clamped(to: -24 ... 24)
        virtualDistance = virtualDistance.clamped(to: Self.virtualDistanceRange)
        width = width.clamped(to: 0.35 ... 0.95)
        height = height.clamped(to: 0.30 ... 0.90)
    }
}

struct WorkspaceWindow: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var source: WindowSource
    var transform: WindowTransform3DoF
    var zIndex: Int
    var isMinimized: Bool

    var kind: WindowKind { source.kind }

    var systemImage: String {
        switch source {
        case .pwa(_, displayMode: .widget): "rectangle.3.group.fill"
        case .pwa: "app.fill"
        default: kind.systemImage
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        source: WindowSource,
        transform: WindowTransform3DoF = .centered,
        zIndex: Int = 0,
        isMinimized: Bool = false
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.transform = transform
        self.zIndex = zIndex
        self.isMinimized = isMinimized
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
