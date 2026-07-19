import Foundation
import XCTest
@testable import ExtendReality

final class SloppyVoiceTransportTests: XCTestCase {
    func testAuthVoiceConfigSessionRecoveryAndAttachmentEncoding() async throws {
        let recorder = VoiceRequestRecorder()
        VoiceURLProtocol.handler = { request in
            recorder.record(request)
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/v1/voice/config"):
                return (200, Self.json([
                    "enabled": true,
                    "effectiveProvider": "local",
                    "localAvailable": true,
                    "input": ["mode": "push_to_talk", "language": "en-US", "previewBeforeSend": true],
                    "local": ["enabled": true, "voiceName": "Samantha", "rate": 1.0, "pitch": 1.0],
                ]))
            case ("GET", "/v1/agents/sloppy/sessions/missing"):
                return (404, Data("not found".utf8))
            case ("POST", "/v1/agents/sloppy/sessions"):
                return (200, Self.json(["id": "replacement", "agentId": "sloppy", "title": "ExtendReality"]))
            case ("POST", "/v1/agents/sloppy/sessions/replacement/messages"):
                return (200, Self.json([
                    "appendedEvents": [[
                        "message": [
                            "role": "assistant",
                            "segments": [["kind": "text", "text": "Voice ready"]],
                        ],
                    ]],
                ]))
            default:
                return (500, Data("unexpected request".utf8))
            }
        }
        defer { VoiceURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let transport = URLSessionSloppyVoiceTransport(session: urlSession)
        let settings = VoiceAssistantSettingsSnapshot(
            isEnabled: true,
            coreURL: try XCTUnwrap(URL(string: "http://sloppy.local:25101")),
            dashboardURL: try XCTUnwrap(URL(string: "http://sloppy.local:25102")),
            authToken: "secret-token",
            agentID: "sloppy",
            sharesActiveContext: true
        )

        let config = try await transport.voiceConfiguration(settings: settings)
        XCTAssertEqual(config.input.mode, "push_to_talk")
        let session = try await transport.ensureSession(
            agentID: "sloppy",
            preferredSessionID: "missing",
            settings: settings
        )
        XCTAssertEqual(session.id, "replacement")

        let attachment = SloppyAttachmentUpload(
            name: "context.jpg",
            mimeType: "image/jpeg",
            sizeBytes: 3,
            contentBase64: "AQID"
        )
        let response = try await transport.postMessage(
            agentID: "sloppy",
            sessionID: session.id,
            content: "What is this?",
            attachments: [attachment],
            settings: settings
        )
        XCTAssertEqual(response, "Voice ready")

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer secret-token" })
        let createBody = try XCTUnwrap(requests.first { $0.path.hasSuffix("/sessions") }?.body)
        let createJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: createBody) as? [String: Any])
        XCTAssertEqual(createJSON["title"] as? String, "ExtendReality")
        let messageBody = try XCTUnwrap(requests.first { $0.path.hasSuffix("/messages") }?.body)
        let messageJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: messageBody) as? [String: Any])
        let attachments = try XCTUnwrap(messageJSON["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["contentBase64"] as? String, "AQID")
    }

    func testStreamEnvelopeDecodesDeltaFinalErrorAndClose() throws {
        let decoder = JSONDecoder()
        let delta = try decoder.decode(
            SessionStreamEnvelope.self,
            from: Data(#"{"kind":"session_delta","message":"Hel"}"#.utf8)
        )
        XCTAssertEqual(delta.update, .delta("Hel"))

        let final = try decoder.decode(
            SessionStreamEnvelope.self,
            from: Data(#"{"kind":"session_event","event":{"message":{"role":"assistant","segments":[{"kind":"text","text":"Hello"}]}}}"#.utf8)
        )
        XCTAssertEqual(final.update, .assistantMessage("Hello"))

        let error = try decoder.decode(
            SessionStreamEnvelope.self,
            from: Data(#"{"kind":"session_error","message":"offline"}"#.utf8)
        )
        XCTAssertEqual(error.update, .error("offline"))

        let closed = try decoder.decode(
            SessionStreamEnvelope.self,
            from: Data(#"{"kind":"session_closed"}"#.utf8)
        )
        XCTAssertEqual(closed.update, .closed)
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class VoiceRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RecordedVoiceRequest] = []

    func record(_ request: URLRequest) {
        let recorded = RecordedVoiceRequest(
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: Self.readBody(from: request)
        )
        lock.lock()
        requests.append(recorded)
        lock.unlock()
    }

    func snapshot() -> [RecordedVoiceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct RecordedVoiceRequest: Sendable {
    var path: String
    var authorization: String?
    var body: Data?
}

private final class VoiceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: SloppyTransportError.invalidResponse)
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
