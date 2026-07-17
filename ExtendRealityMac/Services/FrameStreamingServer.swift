import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Network
import UniformTypeIdentifiers

@MainActor
final class FrameStreamingServer {
    private enum Route: Equatable {
        case primary
        case display(CGDirectDisplayID)
    }

    private struct Client {
        let connection: NWConnection
        let route: Route
    }

    private let queue = DispatchQueue(label: "com.vladprusakov.ExtendReality.streaming")
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var layout: StreamLayout = .single
    private var displays: [CaptureDisplay] = []
    private var latestFrames: [CGDirectDisplayID: CGImage] = [:]
    private var latestComposite: CGImage?
    private var lastPublishTime: ContinuousClock.Instant?
    private var publicAddress: URL?

    var onAddressChanged: ((URL?) -> Void)?
    var onViewerCountChanged: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStartRequested: ((StreamLayout) async throws -> Void)?

    func updateMetadata(layout: StreamLayout, displays: [CaptureDisplay]) {
        self.layout = layout
        self.displays = displays
    }

    func start() throws {
        guard listener == nil else { return }

        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "ExtendReality Mac",
            type: "_extend-reality._tcp"
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                self?.handleListenerState(state, listener: listener)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        latestFrames.removeAll()
        latestComposite = nil
        lastPublishTime = nil
        publicAddress = nil
        onAddressChanged?(nil)
        onViewerCountChanged?(0)
    }

    func publish(
        frames: [CGDirectDisplayID: CGImage],
        composite: CGImage?,
        layout: StreamLayout
    ) {
        latestFrames = frames
        latestComposite = composite
        self.layout = layout

        let now = ContinuousClock.now
        if let lastPublishTime, now - lastPublishTime < .milliseconds(80) {
            return
        }
        lastPublishTime = now

        let routes = Set(clients.values.map { client in
            switch client.route {
            case .primary: "primary"
            case .display(let id): "display:\(id)"
            }
        })

        var encodedFrames: [String: Data] = [:]
        for routeKey in routes {
            let image: CGImage?
            if routeKey == "primary" {
                image = primaryImage
            } else if let rawID = routeKey.split(separator: ":").last,
                      let id = CGDirectDisplayID(rawID) {
                image = latestFrames[id]
            } else {
                image = nil
            }

            if let image, let jpeg = Self.jpegData(from: image) {
                encodedFrames[routeKey] = jpeg
            }
        }

        for (id, client) in clients {
            let key: String = switch client.route {
            case .primary: "primary"
            case .display(let displayID): "display:\(displayID)"
            }
            guard let jpeg = encodedFrames[key] else { continue }
            send(jpeg: jpeg, to: id, connection: client.connection)
        }
    }

    private var primaryImage: CGImage? {
        if layout == .ultrawide {
            return latestComposite
        }
        return displays.lazy.compactMap { self.latestFrames[$0.id] }.first
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener?) {
        switch state {
        case .ready:
            guard let port = listener?.port else { return }
            let hostname = ProcessInfo.processInfo.hostName
            publicAddress = URL(string: "http://\(hostname):\(port.rawValue)/")
            onAddressChanged?(publicAddress)
        case .failed(let error):
            stop()
            onFailure?(error.localizedDescription)
        case .cancelled:
            onAddressChanged?(nil)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .failed = state else {
                if case .cancelled = state {
                    Task { @MainActor [weak self, weak connection] in
                        self?.remove(connection: connection)
                    }
                }
                return
            }
            Task { @MainActor [weak self, weak connection] in
                self?.remove(connection: connection)
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    connection.cancel()
                    self.onFailure?(error.localizedDescription)
                    return
                }
                var requestData = accumulated
                if let data {
                    requestData.append(data)
                }
                guard requestData.count <= 65_536 else {
                    self.sendResponse(
                        status: "413 Payload Too Large",
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Request too large".utf8),
                        to: connection
                    )
                    return
                }
                guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete else {
                    self.receiveRequest(on: connection, accumulated: requestData)
                    return
                }
                guard let request = String(data: requestData, encoding: .utf8),
                      let firstLine = request.split(separator: "\r\n").first else {
                    self.sendNotFound(to: connection)
                    return
                }
                let parts = firstLine.split(separator: " ")
                guard parts.count >= 2 else {
                    self.sendNotFound(to: connection)
                    return
                }
                self.route(method: String(parts[0]), path: String(parts[1]), connection: connection)
            }
        }
    }

    private func route(method: String, path: String, connection: NWConnection) {
        if path == "/" {
            sendHTML(streamPath: "/stream.mjpeg", to: connection)
        } else if path == "/manifest.json" {
            sendManifest(to: connection)
        } else if path == "/stream.mjpeg" {
            beginStream(.primary, connection: connection)
        } else if method == "POST", path.hasPrefix("/api/v1/stream/start") {
            handleStartRequest(path: path, connection: connection)
        } else if method == "GET", path == "/api/v1/status" {
            sendStatus(to: connection)
        } else if path.hasPrefix("/display/"), !path.hasSuffix(".mjpeg") {
            let rawID = path.replacingOccurrences(of: "/display/", with: "")
            guard let id = CGDirectDisplayID(rawID), displays.contains(where: { $0.id == id }) else {
                sendNotFound(to: connection)
                return
            }
            sendHTML(streamPath: "/display/\(id).mjpeg", to: connection)
        } else if path.hasPrefix("/display/"), path.hasSuffix(".mjpeg") {
            let rawID = path
                .replacingOccurrences(of: "/display/", with: "")
                .replacingOccurrences(of: ".mjpeg", with: "")
            guard let id = CGDirectDisplayID(rawID), displays.contains(where: { $0.id == id }) else {
                sendNotFound(to: connection)
                return
            }
            beginStream(.display(id), connection: connection)
        } else {
            sendNotFound(to: connection)
        }
    }

    private func handleStartRequest(path: String, connection: NWConnection) {
        guard let components = URLComponents(string: "http://localhost\(path)"),
              let rawLayout = components.queryItems?.first(where: { $0.name == "layout" })?.value,
              let requestedLayout = StreamLayout(rawValue: rawLayout) else {
            sendAPIError("A valid layout query parameter is required.", status: "400 Bad Request", to: connection)
            return
        }
        guard let onStartRequested else {
            sendAPIError("The capture controller is unavailable.", status: "503 Service Unavailable", to: connection)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onStartRequested(requestedLayout)
                guard let session = self.makeRemoteSession() else {
                    self.sendAPIError("The stream address is not ready.", status: "503 Service Unavailable", to: connection)
                    return
                }
                let body = (try? JSONEncoder().encode(session)) ?? Data()
                self.sendResponse(status: "200 OK", contentType: "application/json", body: body, to: connection)
            } catch {
                self.sendAPIError(error.localizedDescription, status: "409 Conflict", to: connection)
            }
        }
    }

    private func beginStream(_ route: Route, connection: NWConnection) {
        let id = UUID()
        clients[id] = Client(connection: connection, route: route)
        onViewerCountChanged?(clients.count)
        let header = """
        HTTP/1.1 200 OK\r
        Cache-Control: no-store, no-cache, must-revalidate\r
        Connection: close\r
        Content-Type: multipart/x-mixed-replace; boundary=frame\r
        \r

        """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.remove(clientID: id) }
        })
    }

    private func send(jpeg: Data, to clientID: UUID, connection: NWConnection) {
        var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.remove(clientID: clientID) }
        })
    }

    private func sendHTML(streamPath: String, to connection: NWConnection) {
        let html = """
        <!doctype html>
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>ExtendReality Mac</title>
        <style>html,body{margin:0;background:#090b10;color:white;font:15px system-ui;height:100%}body{display:grid;place-items:center}img{max-width:100%;max-height:100%;object-fit:contain}</style>
        <img src="\(streamPath)" alt="ExtendReality display stream">
        """
        sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8), to: connection)
    }

    private func sendManifest(to connection: NWConnection) {
        let payload: [String: Any] = [
            "version": 1,
            "layout": layout.rawValue,
            "primaryStream": "/stream.mjpeg",
            "displays": displays.map { display in
                [
                    "id": display.id,
                    "name": display.name,
                    "width": display.width,
                    "height": display.height,
                    "stream": "/display/\(display.id).mjpeg",
                ] as [String: Any]
            },
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendResponse(status: "200 OK", contentType: "application/json", body: body, to: connection)
    }

    private func sendStatus(to connection: NWConnection) {
        let payload: [String: Any] = [
            "version": 1,
            "layout": layout.rawValue,
            "ready": publicAddress != nil,
            "streaming": !latestFrames.isEmpty || latestComposite != nil,
            "viewers": clients.count,
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendResponse(status: "200 OK", contentType: "application/json", body: body, to: connection)
    }

    private func makeRemoteSession() -> RemoteStreamSession? {
        guard let publicAddress else { return nil }
        let endpoints: [RemoteStreamEndpoint]
        if layout == .multiple {
            endpoints = displays.map { display in
                RemoteStreamEndpoint(
                    id: String(display.id),
                    name: display.name,
                    url: publicAddress
                        .appendingPathComponent("display")
                        .appendingPathComponent(String(display.id))
                )
            }
        } else {
            endpoints = [
                RemoteStreamEndpoint(
                    id: "primary",
                    name: layout == .ultrawide ? "Mac Ultrawide" : (displays.first?.name ?? "Mac"),
                    url: publicAddress
                )
            ]
        }
        return RemoteStreamSession(version: 1, layout: layout, streams: endpoints)
    }

    private func sendAPIError(_ message: String, status: String, to connection: NWConnection) {
        let body = (try? JSONEncoder().encode(RemoteStreamAPIError(error: message))) ?? Data()
        sendResponse(status: status, contentType: "application/json", body: body, to: connection)
    }

    private func sendNotFound(to connection: NWConnection) {
        sendResponse(
            status: "404 Not Found",
            contentType: "text/plain; charset=utf-8",
            body: Data("Not found".utf8),
            to: connection
        )
    }

    private func sendResponse(
        status: String,
        contentType: String,
        body: Data,
        to connection: NWConnection
    ) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func remove(connection: NWConnection?) {
        guard let connection,
              let id = clients.first(where: { $0.value.connection === connection })?.key else { return }
        remove(clientID: id)
    }

    private func remove(clientID: UUID) {
        clients.removeValue(forKey: clientID)?.connection.cancel()
        onViewerCountChanged?(clients.count)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
