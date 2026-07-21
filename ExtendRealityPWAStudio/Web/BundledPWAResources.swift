import Foundation
import Network
import UniformTypeIdentifiers
import WebKit

enum BundledPWAResources {
    static let scheme = "extendreality-pwa"
    static let host = "bundled"

    static func appURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/"
        return components.url!
    }

    static func resourceRoot(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "PWAApps", withExtension: nil)
    }
}

struct BundledPWAResource {
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

struct BundledPWAResourceStore: Sendable {
    private let resourceRoot: URL?

    init(resourceRoot: URL?) {
        self.resourceRoot = resourceRoot?.standardizedFileURL
    }

    func resourceURL(for requestURL: URL) throws -> URL {
        guard let resourceRoot else { throw URLError(.fileDoesNotExist) }

        let decodedPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        var components = decodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw URLError(.fileDoesNotExist)
        }
        if requestURL.hasDirectoryPath {
            components.append("index.html")
        }

        let resourceURL = components.reduce(resourceRoot) { partialURL, component in
            partialURL.appending(path: String(component))
        }.standardizedFileURL
        let rootPath = resourceRoot.path.hasSuffix("/") ? resourceRoot.path : resourceRoot.path + "/"
        guard resourceURL.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: resourceURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        return resourceURL
    }

    func resource(for requestURL: URL) throws -> BundledPWAResource {
        let resourceURL = try resourceURL(for: requestURL)
        return BundledPWAResource(
            data: try Data(contentsOf: resourceURL, options: .mappedIfSafe),
            mimeType: mimeType(for: resourceURL),
            textEncodingName: textEncodingName(for: resourceURL)
        )
    }

    private func mimeType(for resourceURL: URL) -> String {
        switch resourceURL.pathExtension.lowercased() {
        case "webmanifest": "application/manifest+json"
        case "js", "mjs": "text/javascript"
        default: UTType(filenameExtension: resourceURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        }
    }

    private func textEncodingName(for resourceURL: URL) -> String? {
        switch resourceURL.pathExtension.lowercased() {
        case "css", "html", "js", "json", "mjs", "svg", "webmanifest": "utf-8"
        default: nil
        }
    }
}

final class BundledPWAResourceHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let resourceStore: BundledPWAResourceStore

    init(resourceRoot: URL? = BundledPWAResources.resourceRoot()) {
        resourceStore = BundledPWAResourceStore(resourceRoot: resourceRoot)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            let requestURL = try requestedURL(for: urlSchemeTask.request)
            let resource = try resource(for: requestURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: resource.mimeType,
                expectedContentLength: resource.data.count,
                textEncodingName: resource.textEncodingName
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func requestedURL(for request: URLRequest) throws -> URL {
        guard let url = request.url,
              url.scheme?.lowercased() == BundledPWAResources.scheme,
              url.host?.lowercased() == BundledPWAResources.host else {
            throw URLError(.unsupportedURL)
        }
        return url
    }

    func resourceURL(for requestURL: URL) throws -> URL {
        try resourceStore.resourceURL(for: requestURL)
    }

    func resource(for requestURL: URL) throws -> BundledPWAResource {
        try resourceStore.resource(for: requestURL)
    }
}

final class BundledPWAHTTPServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case missingResources
        case unavailable
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .missingResources: "Bundled PWA resources are missing from the app."
            case .unavailable: "The bundled PWA loopback server is unavailable."
            case .invalidURL: "The bundled PWA loopback URL is invalid."
            }
        }
    }

    private let listener: NWListener
    private let resourceStore: BundledPWAResourceStore
    private let queue = DispatchQueue(label: "com.extendreality.pwa-studio.bundled-http")
    private let lock = NSLock()
    private var readyURL: URL?
    private var startupError: Error?
    private var continuations: [CheckedContinuation<URL, Error>] = []

    init(resourceRoot: URL? = BundledPWAResources.resourceRoot()) throws {
        guard let resourceRoot else { throw ServerError.missingResources }
        resourceStore = BundledPWAResourceStore(resourceRoot: resourceRoot)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.update(state)
        }
        listener.start(queue: queue)
    }

    deinit {
        listener.cancel()
    }

    func appURL(path: String) async throws -> URL {
        let baseURL = try await baseURL()
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw ServerError.invalidURL }
        return baseURL.appending(path: path, directoryHint: .isDirectory)
    }

    private func baseURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let readyURL {
                lock.unlock()
                continuation.resume(returning: readyURL)
            } else if let startupError {
                lock.unlock()
                continuation.resume(throwing: startupError)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                finishStartup(with: .failure(ServerError.invalidURL))
                return
            }
            finishStartup(with: .success(url))
        case .failed(let error):
            finishStartup(with: .failure(error))
        case .cancelled:
            finishStartup(with: .failure(ServerError.unavailable))
        default:
            break
        }
    }

    private func finishStartup(with result: Result<URL, Error>) {
        lock.lock()
        switch result {
        case .success(let url): readyURL = url
        case .failure(let error): startupError = error
        }
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()

        for continuation in waiting {
            continuation.resume(with: result)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(from: connection, buffer: Data())
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = buffer
            if let data { request.append(data) }
            if request.count > 65_536 {
                sendError(431, reason: "Request Header Fields Too Large", to: connection)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(to: request, on: connection)
            } else if error != nil || isComplete {
                sendError(400, reason: "Bad Request", to: connection)
            } else {
                receiveRequest(from: connection, buffer: request)
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        guard let header = String(data: request, encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first else {
            sendError(400, reason: "Bad Request", to: connection)
            return
        }
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3 else {
            sendError(400, reason: "Bad Request", to: connection)
            return
        }
        let method = String(fields[0])
        guard method == "GET" || method == "HEAD" else {
            sendError(405, reason: "Method Not Allowed", to: connection)
            return
        }
        guard let requestURL = URL(string: "http://bundled\(fields[1])") else {
            sendError(400, reason: "Bad Request", to: connection)
            return
        }

        do {
            let resource = try resourceStore.resource(for: requestURL)
            var response = Data(httpHeaders(
                status: 200,
                reason: "OK",
                contentLength: resource.data.count,
                contentType: resource.mimeType,
                textEncodingName: resource.textEncodingName
            ).utf8)
            if method == "GET" { response.append(resource.data) }
            send(response, to: connection)
        } catch {
            sendError(404, reason: "Not Found", to: connection)
        }
    }

    private func sendError(_ status: Int, reason: String, to connection: NWConnection) {
        let body = Data("\(status) \(reason)\n".utf8)
        var response = Data(httpHeaders(
            status: status,
            reason: reason,
            contentLength: body.count,
            contentType: "text/plain",
            textEncodingName: "utf-8"
        ).utf8)
        response.append(body)
        send(response, to: connection)
    }

    private func httpHeaders(
        status: Int,
        reason: String,
        contentLength: Int,
        contentType: String,
        textEncodingName: String?
    ) -> String {
        let charset = textEncodingName.map { "; charset=\($0)" } ?? ""
        return """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\(charset)\r
        Content-Length: \(contentLength)\r
        Cache-Control: no-cache\r
        Referrer-Policy: strict-origin-when-cross-origin\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
    }

    private func send(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
