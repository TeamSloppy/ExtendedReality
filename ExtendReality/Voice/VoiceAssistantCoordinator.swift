import Foundation
import Observation

@MainActor
@Observable
final class VoiceAssistantCoordinator {
    private(set) var state: VoiceAssistantState = .idle {
        didSet { onStateChange?() }
    }
    private(set) var availableAgents: [SloppyAgentSummary] = []
    private(set) var connectionStatus = "Not checked"
    let settings: VoiceAssistantSettings

    @ObservationIgnored private let transport: any SloppyVoiceTransport
    @ObservationIgnored private let capture: any VoiceCapturing
    @ObservationIgnored private let localTranscriber: any LocalVoiceTranscribing
    @ObservationIgnored private let player: any VoicePlaying
    @ObservationIgnored private let contextProvider: any AssistantContextProviding
    @ObservationIgnored private let workspace: WorkspaceStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cancellationAutoHideDuration: Duration
    @ObservationIgnored private var voiceConfig: VoiceModeConfiguration = .localFallback
    @ObservationIgnored private var capturedContext: AssistantContext = .empty
    @ObservationIgnored private var contextTask: Task<AssistantContext, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<String?, Never>?
    @ObservationIgnored private var cancellationHideTask: Task<Void, Never>?
    @ObservationIgnored var onStateChange: (() -> Void)?

    init(
        settings: VoiceAssistantSettings,
        workspace: WorkspaceStore,
        contextProvider: any AssistantContextProviding,
        transport: any SloppyVoiceTransport = URLSessionSloppyVoiceTransport(),
        capture: any VoiceCapturing = NativeVoiceCapture(),
        localTranscriber: any LocalVoiceTranscribing = NativeLocalVoiceTranscriber(),
        player: any VoicePlaying = NativeVoicePlayer(),
        defaults: UserDefaults = .standard,
        cancellationAutoHideDuration: Duration = .seconds(4)
    ) {
        self.settings = settings
        self.workspace = workspace
        self.contextProvider = contextProvider
        self.transport = transport
        self.capture = capture
        self.localTranscriber = localTranscriber
        self.player = player
        self.defaults = defaults
        self.cancellationAutoHideDuration = cancellationAutoHideDuration
    }

    var actionTitle: String {
        switch state.phase {
        case .listening: "Stop"
        case .preview: "Send"
        case .speaking: "Ask"
        case .transcribing, .awaitingAgent: "Cancel"
        default: "Voice"
        }
    }

    var actionSystemImage: String {
        switch state.phase {
        case .listening: "stop.fill"
        case .preview: "paperplane.fill"
        case .transcribing, .awaitingAgent: "xmark"
        default: "microphone.fill"
        }
    }

    func toggle() {
        switch state.phase {
        case .listening:
            operationTask = Task { @MainActor [weak self] in await self?.finishRecording() }
        case .preview:
            operationTask = Task { @MainActor [weak self] in await self?.sendPreview() }
        case .speaking:
            player.stop()
            operationTask = Task { @MainActor [weak self] in await self?.startListening() }
        case .transcribing, .awaitingAgent:
            cancel()
        case .idle, .error, .cancelled:
            beginListening()
        }
    }

    func activate() {
        switch state.phase {
        case .idle, .error, .cancelled:
            beginListening()
        case .speaking:
            player.stop()
            beginListening()
        case .listening, .transcribing, .preview, .awaitingAgent:
            break
        }
    }

    func cancel() {
        cancellationHideTask?.cancel()
        operationTask?.cancel()
        operationTask = nil
        streamTask?.cancel()
        streamTask = nil
        contextTask?.cancel()
        contextTask = nil
        capture.cancel()
        player.stop()
        state.phase = .cancelled
        state.statusText = "Cancelled"
        cancellationHideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: cancellationAutoHideDuration)
            guard self.state.phase == .cancelled else { return }
            self.state = .idle
        }
    }

    func testConnection() async {
        guard let snapshot = settings.snapshot else {
            connectionStatus = "Enter valid Sloppy URLs and agent ID."
            return
        }
        connectionStatus = "Connecting…"
        do {
            try await transport.health(settings: snapshot)
            async let config = transport.voiceConfiguration(settings: snapshot)
            async let agents = transport.agents(settings: snapshot)
            let (loadedConfig, loadedAgents) = try await (config, agents)
            voiceConfig = loadedConfig
            availableAgents = loadedAgents
            connectionStatus = loadedConfig.enabled
                ? "Connected · Voice Mode \(loadedConfig.effectiveProvider)"
                : "Connected · Voice Mode disabled in Sloppy"
        } catch {
            connectionStatus = error.localizedDescription
        }
    }

    private func beginListening() {
        cancellationHideTask?.cancel()
        cancellationHideTask = nil
        state.phase = .transcribing
        state.statusText = "Starting Voice Mode…"
        operationTask = Task { @MainActor [weak self] in await self?.startListening() }
    }

    private func startListening() async {
        guard settings.isEnabled else {
            fail("Enable Sloppy Assistant in Settings.")
            return
        }
        guard let snapshot = settings.snapshot else {
            fail("Configure a valid Sloppy server URL and agent ID.")
            return
        }

        do {
            state = VoiceAssistantState(
                phase: .transcribing,
                statusText: "Connecting to Sloppy…",
                agentName: state.agentName,
                pet: state.pet
            )
            async let configRequest = transport.voiceConfiguration(settings: snapshot)
            async let agentsRequest = transport.agents(settings: snapshot)
            let (config, agents) = try await (configRequest, agentsRequest)
            guard config.enabled else {
                fail("Voice Mode is disabled in Sloppy.")
                return
            }
            voiceConfig = config
            availableAgents = agents
            if let agent = agents.first(where: { $0.id == snapshot.agentID }) {
                state.agentName = agent.displayName
                state.pet = agent.pet
            }

            capturedContext = .empty
            if snapshot.sharesActiveContext {
                let activeWindow = workspace.activeWindow
                contextTask = Task { @MainActor [contextProvider] in
                    await contextProvider.context(for: activeWindow)
                }
            }

            let autoSubmit = config.input.mode == "auto_submit"
            try await capture.start(autoSubmit: autoSubmit) { [weak self] in
                guard let self, self.state.phase == .listening else { return }
                self.operationTask = Task { @MainActor [weak self] in await self?.finishRecording() }
            }
            state.phase = .listening
            state.statusText = autoSubmit ? "Listening…" : "Listening · trigger again to send"
            state.transcript = ""
            state.responseText = ""
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finishRecording() async {
        guard state.phase == .listening else { return }
        state.phase = .transcribing
        state.statusText = "Transcribing…"

        do {
            let recording = try capture.stop()
            defer { try? FileManager.default.removeItem(at: recording.fileURL) }
            let transcript = try await transcribe(recording)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw VoiceIOError.noSpeech }
            state.transcript = transcript
            capturedContext = await contextTask?.value ?? .empty
            contextTask = nil

            if voiceConfig.input.previewBeforeSend {
                state.phase = .preview
                state.statusText = "Trigger again to send"
            } else {
                await sendPreview()
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func transcribe(_ recording: CapturedVoice) async throws -> String {
        let snapshot = try requiredSettings()
        if voiceConfig.effectiveProvider == "openai" {
            do {
                let response = try await transport.transcribe(
                    VoiceTranscriptionRequest(
                        audioBase64: recording.data.base64EncodedString(),
                        mimeType: recording.mimeType,
                        language: voiceConfig.input.language,
                        prompt: nil
                    ),
                    settings: snapshot
                )
                return response.text
            } catch where voiceConfig.localAvailable {
                return try await localTranscriber.transcribe(
                    fileURL: recording.fileURL,
                    language: voiceConfig.input.language
                )
            }
        }
        return try await localTranscriber.transcribe(
            fileURL: recording.fileURL,
            language: voiceConfig.input.language
        )
    }

    private func sendPreview() async {
        let transcript = state.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            fail("No speech was detected.")
            return
        }

        do {
            let snapshot = try requiredSettings()
            state.phase = .awaitingAgent
            state.statusText = "Sloppy is thinking…"
            state.responseText = ""
            let session = try await transport.ensureSession(
                agentID: snapshot.agentID,
                preferredSessionID: persistedSessionID(for: snapshot),
                settings: snapshot
            )
            persistSessionID(session.id, for: snapshot)

            let stream = transport.streamSession(
                agentID: snapshot.agentID,
                sessionID: session.id,
                settings: snapshot
            )
            streamTask = Task { @MainActor [weak self] in
                guard let self else { return nil }
                do {
                    for try await update in stream {
                        if let final = self.apply(update) { return final }
                    }
                } catch {
                    // The POST response below remains the authoritative fallback.
                }
                return nil
            }

            let content = "\(capturedContext.promptBlock)\n\nUser request:\n\(transcript)"
            let fallback = try await transport.postMessage(
                agentID: snapshot.agentID,
                sessionID: session.id,
                content: content,
                attachments: capturedContext.attachment.map { [$0] } ?? [],
                settings: snapshot
            )
            let streamed = await streamTask?.value
            let response = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? streamed?.trimmingCharacters(in: .whitespacesAndNewlines)
            streamTask?.cancel()
            streamTask = nil
            guard let response, !response.isEmpty else {
                throw SloppyTransportError.invalidPayload
            }
            state.responseText = response
            await speak(response, settings: snapshot)
        } catch {
            streamTask?.cancel()
            streamTask = nil
            fail(error.localizedDescription)
        }
    }

    private func apply(_ update: SloppyStreamUpdate) -> String? {
        switch update {
        case .delta(let text):
            state.responseText = text
            return nil
        case .assistantMessage(let text):
            state.responseText = text
            return text
        case .error(let message):
            state.statusText = message
            return nil
        case .ready, .closed:
            return nil
        }
    }

    private func speak(_ response: String, settings: VoiceAssistantSettingsSnapshot) async {
        state.phase = .speaking
        state.statusText = "Speaking…"
        let spokenText = String(response.prefix(4_000))

        if voiceConfig.effectiveProvider == "openai" {
            do {
                let speech = try await transport.synthesize(
                    VoiceSpeechRequest(text: spokenText, voice: nil, instructions: nil),
                    settings: settings
                )
                guard let data = Data(base64Encoded: speech.audioBase64) else {
                    throw SloppyTransportError.invalidPayload
                }
                try await player.playAudio(data)
            } catch where voiceConfig.localAvailable {
                await player.speakLocally(spokenText, config: voiceConfig.local)
            } catch {
                state.statusText = "Response ready · audio unavailable"
            }
        } else {
            await player.speakLocally(spokenText, config: voiceConfig.local)
        }

        guard state.phase == .speaking else { return }
        state.statusText = "Done"
        try? await Task.sleep(for: .seconds(3))
        guard state.phase == .speaking else { return }
        state = .idle
    }

    private func requiredSettings() throws -> VoiceAssistantSettingsSnapshot {
        guard let snapshot = settings.snapshot else { throw SloppyTransportError.invalidURL }
        return snapshot
    }

    private func persistedSessionID(for settings: VoiceAssistantSettingsSnapshot) -> String? {
        defaults.string(forKey: sessionDefaultsKey(for: settings))
    }

    private func persistSessionID(_ id: String, for settings: VoiceAssistantSettingsSnapshot) {
        defaults.set(id, forKey: sessionDefaultsKey(for: settings))
    }

    private func sessionDefaultsKey(for settings: VoiceAssistantSettingsSnapshot) -> String {
        let host = settings.coreURL.host ?? "sloppy"
        let port = settings.coreURL.port.map(String.init) ?? "default"
        return "voiceAssistant.session.\(host).\(port).\(settings.agentID)"
    }

    private func fail(_ message: String) {
        capture.cancel()
        player.stop()
        state.phase = .error
        state.statusText = message
    }
}
