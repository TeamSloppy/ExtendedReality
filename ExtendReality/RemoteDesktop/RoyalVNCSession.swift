@preconcurrency import RoyalVNCKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class RoyalVNCSession: NSObject, RemoteDesktopSession {
    let windowID: UUID
    var host: String
    var port: Int = 5900
    var username = ""
    var password = ""
    private(set) var connectionState: RemoteDesktopConnectionState = .disconnected
    private(set) var framebuffer: CGImage?
    private(set) var framebufferSize: CGSize = .zero

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var connection: VNCConnection?

    init(windowID: UUID, keychain: KeychainStore, initialHost: String?) {
        let resolvedHost = initialHost ?? UserDefaults.standard.string(forKey: "vnc.lastHost") ?? ""
        self.windowID = windowID
        self.keychain = keychain
        host = resolvedHost
        username = UserDefaults.standard.string(forKey: "vnc.lastUsername") ?? ""
        password = keychain.string(for: "vnc.\(resolvedHost).password") ?? ""
        super.init()
    }

    func connect() {
        connect(configuration: .init(host: host, port: port, username: username, password: password))
    }

    func connect(configuration: RemoteDesktopConfiguration) {
        guard !configuration.host.isEmpty else {
            connectionState = .failed(message: "Enter the Mac hostname or IP address.")
            return
        }
        disconnect()
        host = configuration.host
        port = configuration.port
        username = configuration.username
        password = configuration.password
        UserDefaults.standard.set(host, forKey: "vnc.lastHost")
        UserDefaults.standard.set(username, forKey: "vnc.lastUsername")
        try? keychain.setString(password, for: "vnc.\(host).password")

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: UInt16(port.clamped(to: 1 ... 65_535)),
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection
        connectionState = .connecting
        connection.connect()
    }

    func disconnect() {
        guard let connection else {
            connectionState = .disconnected
            return
        }
        connectionState = .disconnecting
        connection.disconnect()
    }

    func handle(_ command: InputCommand) {
        guard let connection, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        switch command {
        case .pointerMoved(let position):
            let point = framebufferPoint(for: position)
            connection.mouseMove(x: point.x, y: point.y)
        case .pointerDown(let position):
            let point = framebufferPoint(for: position)
            connection.mouseButtonDown(.left, x: point.x, y: point.y)
        case .pointerUp(let position):
            let point = framebufferPoint(for: position)
            connection.mouseButtonUp(.left, x: point.x, y: point.y)
        case .scroll(let delta):
            let point = framebufferPoint(for: CGPoint(x: 0.5, y: 0.5))
            let wheel: VNCMouseWheel = delta.dy > 0 ? .down : .up
            connection.mouseWheel(wheel, x: point.x, y: point.y, steps: 1)
        case .magnify:
            break
        case .insertText(let text):
            for keyCode in VNCKeyCode.keyCodesFrom(characters: text) {
                connection.keyDown(keyCode)
                connection.keyUp(keyCode)
            }
        case .replaceText:
            break
        case .submitText(let text):
            for keyCode in VNCKeyCode.keyCodesFrom(characters: text) {
                connection.keyDown(keyCode)
                connection.keyUp(keyCode)
            }
        case .back:
            connection.keyDown(.escape)
            connection.keyUp(.escape)
        case .media:
            break
        }
    }

    private func framebufferPoint(for normalized: CGPoint) -> (x: UInt16, y: UInt16) {
        let x = UInt16((normalized.x * framebufferSize.width).clamped(to: 0 ... 65_535))
        let y = UInt16((normalized.y * framebufferSize.height).clamped(to: 0 ... 65_535))
        return (x, y)
    }
}

extension RoyalVNCSession: @preconcurrency VNCConnectionDelegate {
    func connection(
        _ connection: VNCConnection,
        stateDidChange connectionState: VNCConnection.ConnectionState
    ) {
        switch connectionState.status {
        case .connecting:
            self.connectionState = .connecting
        case .connected:
            self.connectionState = .connected
        case .disconnecting:
            self.connectionState = .disconnecting
        case .disconnected:
            if let error = connectionState.error as? VNCError, error.shouldDisplayToUser {
                self.connectionState = .failed(message: String(describing: error))
            } else {
                self.connectionState = .disconnected
            }
            connection.delegate = nil
            self.connection = nil
        @unknown default:
            self.connectionState = .disconnected
        }
    }

    func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: username, password: password))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: password))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        self.framebuffer = framebuffer.cgImage
        framebufferSize = CGSize(width: Int(framebuffer.size.width), height: Int(framebuffer.size.height))
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        self.framebuffer = framebuffer.cgImage
        framebufferSize = CGSize(width: Int(framebuffer.size.width), height: Int(framebuffer.size.height))
    }

    func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        self.framebuffer = framebuffer.cgImage
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
