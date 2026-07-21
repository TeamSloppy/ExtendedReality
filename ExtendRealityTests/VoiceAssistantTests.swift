import Foundation
import XCTest
@testable import ExtendReality

@MainActor
final class VoiceAssistantTests: XCTestCase {
    func testContextBuildsPromptAndAttachment() {
        let image = Data([1, 2, 3])
        let context = AssistantContext(
            surfaceTitle: "Example",
            surfaceKind: "browser",
            url: "https://example.com",
            focusedText: "Selected article",
            screenshotJPEG: image
        )

        XCTAssertTrue(context.promptBlock.contains("Active surface: Example"))
        XCTAssertTrue(context.promptBlock.contains("Focused content: Selected article"))
        XCTAssertEqual(context.attachment?.sizeBytes, image.count)
        XCTAssertEqual(context.attachment?.contentBase64, image.base64EncodedString())
    }

    func testPushToTalkPreviewAndSendStateMachine() async throws {
        let environment = AppEnvironment.preview(windowCount: 0)
        let defaults = UserDefaults(suiteName: "VoiceAssistantTests.\(UUID().uuidString)")!
        let settings = VoiceAssistantSettings(defaults: defaults, keychain: environment.keychain)
        settings.isEnabled = true
        settings.coreURLString = "http://127.0.0.1:25101"
        settings.dashboardURLString = "http://127.0.0.1:25102"
        settings.agentID = "sloppy"
        let capture = StubVoiceCapture()
        let coordinator = VoiceAssistantCoordinator(
            settings: settings,
            workspace: environment.workspace,
            contextProvider: StubContextProvider(),
            transport: StubSloppyTransport(),
            capture: capture,
            localTranscriber: StubLocalTranscriber(),
            player: StubVoicePlayer(),
            defaults: defaults
        )

        coordinator.toggle()
        await waitUntil { coordinator.state.phase == .listening }
        XCTAssertEqual(coordinator.state.phase, .listening)

        coordinator.toggle()
        await waitUntil { coordinator.state.phase == .preview }
        XCTAssertEqual(coordinator.state.transcript, "What am I looking at?")

        coordinator.toggle()
        await waitUntil { coordinator.state.phase == .speaking }
        XCTAssertEqual(coordinator.state.responseText, "This is the Sloppy response.")
        coordinator.cancel()
    }

    func testAutomaticStopInvokesTranscription() async throws {
        let environment = AppEnvironment.preview(windowCount: 0)
        let defaults = UserDefaults(suiteName: "VoiceAssistantAutoTests.\(UUID().uuidString)")!
        let settings = VoiceAssistantSettings(defaults: defaults, keychain: environment.keychain)
        settings.isEnabled = true
        let capture = StubVoiceCapture()
        let coordinator = VoiceAssistantCoordinator(
            settings: settings,
            workspace: environment.workspace,
            contextProvider: StubContextProvider(),
            transport: StubSloppyTransport(inputMode: "auto_submit"),
            capture: capture,
            localTranscriber: StubLocalTranscriber(),
            player: StubVoicePlayer(),
            defaults: defaults
        )

        coordinator.toggle()
        await waitUntil { coordinator.state.phase == .listening }
        capture.simulateAutomaticStop()
        await waitUntil { coordinator.state.phase == .preview }
        XCTAssertEqual(coordinator.state.transcript, "What am I looking at?")
        coordinator.cancel()
    }

    func testVoiceModeActivationIsIdempotentWhileListening() async throws {
        let environment = AppEnvironment.preview(windowCount: 0)
        let defaults = UserDefaults(suiteName: "VoiceAssistantActivationTests.\(UUID().uuidString)")!
        let settings = VoiceAssistantSettings(defaults: defaults, keychain: environment.keychain)
        settings.isEnabled = true
        let coordinator = VoiceAssistantCoordinator(
            settings: settings,
            workspace: environment.workspace,
            contextProvider: StubContextProvider(),
            transport: StubSloppyTransport(),
            capture: StubVoiceCapture(),
            localTranscriber: StubLocalTranscriber(),
            player: StubVoicePlayer(),
            defaults: defaults
        )

        coordinator.activate()
        await waitUntil { coordinator.state.phase == .listening }
        coordinator.activate()

        XCTAssertEqual(coordinator.state.phase, .listening)
        coordinator.cancel()
    }

    func testCancellationStaysVisibleThenAutoHides() async throws {
        let environment = AppEnvironment.preview(windowCount: 0)
        let defaults = UserDefaults(suiteName: "VoiceAssistantCancellationTests.\(UUID().uuidString)")!
        let settings = VoiceAssistantSettings(defaults: defaults, keychain: environment.keychain)
        settings.isEnabled = true
        let coordinator = VoiceAssistantCoordinator(
            settings: settings,
            workspace: environment.workspace,
            contextProvider: StubContextProvider(),
            transport: StubSloppyTransport(),
            capture: StubVoiceCapture(),
            localTranscriber: StubLocalTranscriber(),
            player: StubVoicePlayer(),
            defaults: defaults,
            cancellationAutoHideDuration: .milliseconds(20)
        )

        coordinator.activate()
        await waitUntil { coordinator.state.phase == .listening }
        coordinator.cancel()

        XCTAssertEqual(coordinator.state.phase, .cancelled)
        XCTAssertTrue(coordinator.state.phase.isPresented)
        await waitUntil { coordinator.state.phase == .idle }
        XCTAssertEqual(coordinator.state.phase, .idle)
    }

    func testVoiceModeActivationRouterConsumesOnlyMatchingRequest() throws {
        let router = VoiceModeActivationRouter()
        router.requestActivation()
        let request = try XCTUnwrap(router.pendingRequest)

        router.consume(UUID())
        XCTAssertEqual(router.pendingRequest, request)

        router.consume(request.id)
        XCTAssertNil(router.pendingRequest)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let startedAt = ContinuousClock.now
        while !condition(), ContinuousClock.now - startedAt < timeout {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class StubVoiceCapture: VoiceCapturing {
    var isRecording = false
    private var automaticStop: (@MainActor @Sendable () -> Void)?

    func start(
        autoSubmit: Bool,
        onAutomaticStop: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        isRecording = true
        automaticStop = onAutomaticStop
    }

    func stop() throws -> CapturedVoice {
        isRecording = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-test-\(UUID().uuidString).m4a")
        let data = Data("audio".utf8)
        try data.write(to: url)
        return CapturedVoice(data: data, mimeType: "audio/mp4", fileURL: url)
    }

    func cancel() {
        isRecording = false
        automaticStop = nil
    }

    func simulateAutomaticStop() {
        automaticStop?()
    }
}

@MainActor
private final class StubLocalTranscriber: LocalVoiceTranscribing {
    func transcribe(fileURL: URL, language: String) async throws -> String {
        "What am I looking at?"
    }
}

@MainActor
private final class StubVoicePlayer: VoicePlaying {
    var isPlaying = false

    func playAudio(_ data: Data) async throws {
        isPlaying = true
        isPlaying = false
    }

    func speakLocally(_ text: String, config: VoiceModeConfiguration.Local) async {
        isPlaying = true
        isPlaying = false
    }

    func stop() { isPlaying = false }
}

@MainActor
private final class StubContextProvider: AssistantContextProviding {
    func context(for window: WorkspaceWindow?) async -> AssistantContext {
        AssistantContext(surfaceTitle: "Test", surfaceKind: "browser")
    }
}

private final class StubSloppyTransport: SloppyVoiceTransport, @unchecked Sendable {
    private let inputMode: String

    init(inputMode: String = "push_to_talk") {
        self.inputMode = inputMode
    }

    func health(settings: VoiceAssistantSettingsSnapshot) async throws {}

    func voiceConfiguration(settings: VoiceAssistantSettingsSnapshot) async throws -> VoiceModeConfiguration {
        VoiceModeConfiguration(
            enabled: true,
            effectiveProvider: "local",
            localAvailable: true,
            input: .init(mode: inputMode, language: "en-US", previewBeforeSend: true),
            local: .init(enabled: true, voiceName: "", rate: 1, pitch: 1)
        )
    }

    func agents(settings: VoiceAssistantSettingsSnapshot) async throws -> [SloppyAgentSummary] {
        [SloppyAgentSummary(id: "sloppy", displayName: "SLOPPY", pet: nil)]
    }

    func transcribe(
        _ request: VoiceTranscriptionRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceTranscriptionResponse {
        VoiceTranscriptionResponse(text: "Remote transcript", provider: "openai", model: "test")
    }

    func synthesize(
        _ request: VoiceSpeechRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceSpeechResponse {
        VoiceSpeechResponse(audioBase64: "", mimeType: "audio/mpeg", provider: "openai", model: "test", voice: "test")
    }

    func ensureSession(
        agentID: String,
        preferredSessionID: String?,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> SloppySessionSummary {
        SloppySessionSummary(id: "session", agentId: agentID, title: "ExtendReality")
    }

    func postMessage(
        agentID: String,
        sessionID: String,
        content: String,
        attachments: [SloppyAttachmentUpload],
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> String? {
        "This is the Sloppy response."
    }

    func streamSession(
        agentID: String,
        sessionID: String,
        settings: VoiceAssistantSettingsSnapshot
    ) -> AsyncThrowingStream<SloppyStreamUpdate, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
