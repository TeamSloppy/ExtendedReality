import CoreGraphics
import Foundation

enum RemoteDesktopConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed(message: String)
}

struct RemoteDesktopConfiguration: Equatable, Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String

    init(host: String, port: Int = 5900, username: String = "", password: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

@MainActor
protocol RemoteDesktopSession: InputTarget {
    var connectionState: RemoteDesktopConnectionState { get }
    var framebuffer: CGImage? { get }
    func connect(configuration: RemoteDesktopConfiguration)
    func disconnect()
}

