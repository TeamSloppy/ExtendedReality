import Foundation

protocol SloppyVoiceTransport: Sendable {
    func health(settings: VoiceAssistantSettingsSnapshot) async throws
    func voiceConfiguration(settings: VoiceAssistantSettingsSnapshot) async throws -> VoiceModeConfiguration
    func agents(settings: VoiceAssistantSettingsSnapshot) async throws -> [SloppyAgentSummary]
    func transcribe(
        _ request: VoiceTranscriptionRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceTranscriptionResponse
    func synthesize(
        _ request: VoiceSpeechRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceSpeechResponse
    func ensureSession(
        agentID: String,
        preferredSessionID: String?,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> SloppySessionSummary
    func postMessage(
        agentID: String,
        sessionID: String,
        content: String,
        attachments: [SloppyAttachmentUpload],
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> String?
    func streamSession(
        agentID: String,
        sessionID: String,
        settings: VoiceAssistantSettingsSnapshot
    ) -> AsyncThrowingStream<SloppyStreamUpdate, any Error>
}

enum SloppyTransportError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Sloppy server URL."
        case .invalidResponse: "Sloppy returned an invalid response."
        case .httpStatus(let status, let body): "Sloppy HTTP \(status): \(body)"
        case .invalidPayload: "Sloppy returned an unreadable payload."
        }
    }
}

struct URLSessionSloppyVoiceTransport: SloppyVoiceTransport {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func health(settings: VoiceAssistantSettingsSnapshot) async throws {
        _ = try await data(path: "/health", settings: settings)
    }

    func voiceConfiguration(settings: VoiceAssistantSettingsSnapshot) async throws -> VoiceModeConfiguration {
        try await get("/v1/voice/config", settings: settings)
    }

    func agents(settings: VoiceAssistantSettingsSnapshot) async throws -> [SloppyAgentSummary] {
        try await get("/v1/agents", settings: settings)
    }

    func transcribe(
        _ request: VoiceTranscriptionRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceTranscriptionResponse {
        try await post("/v1/voice/transcriptions", body: request, settings: settings)
    }

    func synthesize(
        _ request: VoiceSpeechRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceSpeechResponse {
        try await post("/v1/voice/speech", body: request, settings: settings)
    }

    func ensureSession(
        agentID: String,
        preferredSessionID: String?,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> SloppySessionSummary {
        let encodedAgent = Self.pathSegment(agentID)
        if let preferredSessionID, !preferredSessionID.isEmpty {
            do {
                let detail: SessionDetail = try await get(
                    "/v1/agents/\(encodedAgent)/sessions/\(Self.pathSegment(preferredSessionID))",
                    settings: settings
                )
                return detail.summary
            } catch SloppyTransportError.httpStatus(let status, _) where status == 404 {
                // The persisted session was removed. Create a replacement below.
            }
        }

        let request = SessionCreateRequest(title: "ExtendReality", kind: "chat")
        return try await post(
            "/v1/agents/\(encodedAgent)/sessions",
            body: request,
            settings: settings
        )
    }

    func postMessage(
        agentID: String,
        sessionID: String,
        content: String,
        attachments: [SloppyAttachmentUpload],
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> String? {
        let body = SessionMessageRequest(
            userId: "extend_reality",
            content: content,
            attachments: attachments,
            spawnSubSession: false,
            mode: "auto"
        )
        let response: SessionMessageResponse = try await post(
            "/v1/agents/\(Self.pathSegment(agentID))/sessions/\(Self.pathSegment(sessionID))/messages",
            body: body,
            settings: settings
        )
        return response.appendedEvents.reversed().compactMap(\.assistantText).first
    }

    func streamSession(
        agentID: String,
        sessionID: String,
        settings: VoiceAssistantSettingsSnapshot
    ) -> AsyncThrowingStream<SloppyStreamUpdate, any Error> {
        guard var components = URLComponents(url: settings.coreURL, resolvingAgainstBaseURL: false) else {
            return AsyncThrowingStream { $0.finish(throwing: SloppyTransportError.invalidURL) }
        }
        components.scheme = settings.coreURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/agents/\(Self.pathSegment(agentID))/sessions/\(Self.pathSegment(sessionID))/ws"
        guard let url = components.url else {
            return AsyncThrowingStream { $0.finish(throwing: SloppyTransportError.invalidURL) }
        }

        var request = URLRequest(url: url)
        if !settings.authToken.isEmpty {
            request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        }

        return AsyncThrowingStream { continuation in
            let socket = session.webSocketTask(with: request)
            let receiveTask = Task {
                do {
                    socket.resume()
                    continuation.yield(.ready)
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .string(let value): data = Data(value.utf8)
                        case .data(let value): data = value
                        @unknown default: continue
                        }
                        let envelope = try decoder.decode(SessionStreamEnvelope.self, from: data)
                        if let update = envelope.update {
                            continuation.yield(update)
                            if update == .closed { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                receiveTask.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func get<Response: Decodable>(
        _ path: String,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> Response {
        let payload = try await data(path: path, settings: settings)
        return try decode(Response.self, from: payload)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> Response {
        let payload = try await data(
            method: "POST",
            path: path,
            body: try encoder.encode(body),
            settings: settings
        )
        return try decode(Response.self, from: payload)
    }

    private func data(
        method: String = "GET",
        path: String,
        body: Data? = nil,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: settings.coreURL)?.absoluteURL else {
            throw SloppyTransportError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !settings.authToken.isEmpty {
            request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SloppyTransportError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SloppyTransportError.httpStatus(
                http.statusCode,
                String(decoding: data.prefix(300), as: UTF8.self)
            )
        }
        return data
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SloppyTransportError.invalidPayload
        }
    }

    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct SessionCreateRequest: Codable {
    var title: String
    var kind: String
}

private struct SessionDetail: Decodable {
    var summary: SloppySessionSummary
}

private struct SessionMessageRequest: Encodable {
    var userId: String
    var content: String
    var attachments: [SloppyAttachmentUpload]
    var spawnSubSession: Bool
    var mode: String
}

private struct SessionMessageResponse: Decodable {
    var appendedEvents: [SessionEvent] = []

    private enum CodingKeys: String, CodingKey { case appendedEvents }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appendedEvents = try container.decodeIfPresent([SessionEvent].self, forKey: .appendedEvents) ?? []
    }
}

struct SessionEvent: Decodable {
    var message: SessionChatMessage?

    private enum CodingKeys: String, CodingKey { case message, event }
    private struct Embedded: Decodable { var message: SessionChatMessage? }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(SessionChatMessage.self, forKey: .message)
            ?? container.decodeIfPresent(Embedded.self, forKey: .event)?.message
    }

    var assistantText: String? {
        guard message?.role == "assistant" else { return nil }
        return message?.text
    }
}

struct SessionChatMessage: Decodable {
    struct Segment: Decodable {
        var kind: String
        var text: String?
    }

    var role: String
    var segments: [Segment]

    var text: String {
        segments.filter { $0.kind == "text" }.compactMap(\.text).joined()
    }
}

struct SessionStreamEnvelope: Decodable {
    var kind: String
    var message: String?
    var event: SessionEvent?

    var update: SloppyStreamUpdate? {
        switch kind {
        case "session_ready": .ready
        case "session_delta": message.map(SloppyStreamUpdate.delta)
        case "session_event": event?.assistantText.map(SloppyStreamUpdate.assistantMessage)
        case "session_error": .error(message ?? "Sloppy session failed.")
        case "session_closed": .closed
        case "heartbeat": nil
        default: nil
        }
    }
}
