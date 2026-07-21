@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import ExtendReality

@MainActor
final class WakeWordTests: XCTestCase {
    func testMatcherRecognizesSupportedAliasesAsWholeWords() {
        XCTAssertTrue(WakeWordMatcher.containsWakeWord("Sloppy"))
        XCTAssertTrue(WakeWordMatcher.containsWakeWord("sloppy!"))
        XCTAssertTrue(WakeWordMatcher.containsWakeWord("Привет, Слоппи."))
        XCTAssertTrue(WakeWordMatcher.containsWakeWord("слопи"))

        XCTAssertFalse(WakeWordMatcher.containsWakeWord("copy floppy Sophie"))
        XCTAssertFalse(WakeWordMatcher.containsWakeWord("sloppily"))
        XCTAssertFalse(WakeWordMatcher.containsWakeWord("notsloppy"))
    }

    func testStablePartialResultTriggersVoiceModeOnceAndSuspendsDetector() async {
        let fixture = makeFixture()
        await fixture.startListening()

        fixture.recognizer.emit(["Sloppy"], isFinal: false)
        XCTAssertEqual(fixture.coordinator.state.phase, .idle)

        fixture.recognizer.emit(["Sloppy"], isFinal: false)
        await waitUntil { fixture.capture.startCount == 1 }

        XCTAssertEqual(fixture.controller.state, .suspended)
        fixture.recognizer.emit(["Sloppy"], isFinal: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.capture.startCount, 1)
        fixture.coordinator.cancel()
    }

    func testNearMatchesDoNotTriggerVoiceMode() async {
        let fixture = makeFixture()
        await fixture.startListening()

        for value in ["copy", "floppy", "Sophie", "sloppily"] {
            fixture.recognizer.emit([value], isFinal: false)
            fixture.recognizer.emit([value], isFinal: true)
        }

        XCTAssertEqual(fixture.coordinator.state.phase, .idle)
        XCTAssertEqual(fixture.capture.startCount, 0)
        XCTAssertEqual(fixture.controller.state, .listening)
    }

    func testDetectorStopsOutsideForegroundAndRestartsWhenActive() async {
        let fixture = makeFixture(wakeWordEnabled: false)
        fixture.controller.setForegroundActive(true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.controller.state, .disabled)
        XCTAssertEqual(fixture.driver.startCount, 0)

        fixture.settings.wakeWordEnabled = true
        await waitUntil { fixture.controller.state == .listening }
        XCTAssertTrue(fixture.hub.isCapturing)

        fixture.controller.setForegroundActive(false)
        XCTAssertEqual(fixture.controller.state, .suspended)
        XCTAssertFalse(fixture.hub.isCapturing)
        XCTAssertGreaterThan(fixture.driver.stopCount, 0)
    }

    func testDetectorRearmsAfterVoiceModeError() async {
        let fixture = makeFixture(voiceModeEnabled: false)
        await fixture.startListening()

        fixture.recognizer.emit(["Sloppy"], isFinal: true)
        await waitUntil { fixture.coordinator.state.phase == .error }
        await waitUntil { fixture.controller.state == .listening }

        XCTAssertEqual(fixture.controller.state, .listening)
    }

    func testRecognitionTaskRestartsAfterTransientFailure() async {
        let fixture = makeFixture()
        await fixture.startListening()
        XCTAssertEqual(fixture.recognizer.startCount, 1)

        fixture.recognizer.complete(error: WakeTestError.transient)
        await waitUntil { fixture.recognizer.startCount == 2 }

        XCTAssertEqual(fixture.controller.state, .listening)
        XCTAssertTrue(fixture.hub.isCapturing)
    }

    func testUnavailableOnDeviceRecognitionDisablesPreference() async {
        let fixture = makeFixture(supportsOnDeviceRecognition: false)
        fixture.controller.setForegroundActive(true)
        await waitUntil {
            if case .unavailable = fixture.controller.state { return true }
            return false
        }

        XCTAssertFalse(fixture.settings.wakeWordEnabled)
        XCTAssertEqual(fixture.driver.startCount, 0)
    }

    func testDeniedMicrophonePermissionDisablesPreferenceAndOffersSettings() async {
        let fixture = makeFixture(microphoneGranted: false)
        fixture.controller.setForegroundActive(true)
        await waitUntil {
            if case .unavailable = fixture.controller.state { return true }
            return false
        }

        XCTAssertFalse(fixture.settings.wakeWordEnabled)
        XCTAssertTrue(fixture.controller.state.opensSystemSettings)
        XCTAssertEqual(fixture.driver.startCount, 0)
    }

    func testMicrophoneHubFansOutAndExclusiveLeasePausesConsumers() throws {
        let driver = StubMicrophoneCaptureDriver()
        let hub = MicrophoneAudioHub(driver: driver, permissionRequester: { true })
        let first = SendableCounter()
        let second = SendableCounter()
        let retention = hub.beginAudioSessionRetention()

        hub.setForegroundActive(true)
        let firstID = try hub.addConsumer { _ in first.increment() }
        let secondID = try hub.addConsumer { _ in second.increment() }
        driver.emit(makeBuffer())
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1)
        XCTAssertEqual(driver.startCount, 1)

        let lease = hub.beginExclusiveAccess()
        driver.emit(makeBuffer())
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1)
        XCTAssertFalse(hub.isCapturing)

        lease.release()
        driver.emit(makeBuffer())
        XCTAssertEqual(first.value, 2)
        XCTAssertEqual(second.value, 2)
        XCTAssertEqual(driver.startCount, 2)

        hub.removeConsumer(firstID)
        hub.removeConsumer(secondID)
        XCTAssertFalse(hub.isCapturing)
        XCTAssertEqual(driver.lastDeactivatesAudioSession, false)

        retention.release()
        XCTAssertEqual(driver.lastDeactivatesAudioSession, true)
    }

    private func makeFixture(
        wakeWordEnabled: Bool = true,
        supportsOnDeviceRecognition: Bool = true,
        microphoneGranted: Bool = true,
        voiceModeEnabled: Bool = true
    ) -> WakeWordFixture {
        let environment = AppEnvironment.preview(windowCount: 0)
        let defaults = UserDefaults(suiteName: "WakeWordTests.\(UUID().uuidString)")!
        let settings = VoiceAssistantSettings(defaults: defaults, keychain: environment.keychain)
        settings.isEnabled = true
        settings.wakeWordEnabled = wakeWordEnabled
        let capture = WakeTestCapture()
        let coordinator = VoiceAssistantCoordinator(
            settings: settings,
            workspace: environment.workspace,
            contextProvider: WakeTestContextProvider(),
            transport: WakeTestTransport(voiceModeEnabled: voiceModeEnabled),
            capture: capture,
            localTranscriber: WakeTestTranscriber(),
            player: WakeTestPlayer(),
            defaults: defaults
        )
        let driver = StubMicrophoneCaptureDriver()
        let hub = MicrophoneAudioHub(
            driver: driver,
            permissionRequester: { microphoneGranted }
        )
        let recognizer = StubWakeWordRecognizer(
            supportsOnDeviceRecognition: supportsOnDeviceRecognition
        )
        let controller = WakeWordController(
            settings: settings,
            assistant: coordinator,
            microphoneHub: hub,
            recognizer: recognizer
        )
        coordinator.onStateChange = { [weak controller] in
            controller?.assistantStateDidChange()
        }
        settings.onWakeWordConfigurationChange = { [weak controller] in
            controller?.configurationDidChange()
        }
        return WakeWordFixture(
            settings: settings,
            coordinator: coordinator,
            capture: capture,
            controller: controller,
            recognizer: recognizer,
            driver: driver,
            hub: hub
        )
    }

    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        return buffer
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
private struct WakeWordFixture {
    let settings: VoiceAssistantSettings
    let coordinator: VoiceAssistantCoordinator
    let capture: WakeTestCapture
    let controller: WakeWordController
    let recognizer: StubWakeWordRecognizer
    let driver: StubMicrophoneCaptureDriver
    let hub: MicrophoneAudioHub

    func startListening() async {
        controller.setForegroundActive(true)
        let startedAt = ContinuousClock.now
        while controller.state != .listening,
              ContinuousClock.now - startedAt < .seconds(2) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class StubMicrophoneCaptureDriver: MicrophoneCaptureDriving {
    private var handler: MicrophoneBufferHandler?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastDeactivatesAudioSession: Bool?

    func start(bufferHandler: @escaping MicrophoneBufferHandler) throws {
        handler = bufferHandler
        isRunning = true
        startCount += 1
    }

    func stop(deactivateAudioSession: Bool) {
        isRunning = false
        stopCount += 1
        lastDeactivatesAudioSession = deactivateAudioSession
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        handler?(buffer)
    }
}

@MainActor
private final class StubWakeWordRecognizer: WakeWordRecognizing {
    let supportsOnDeviceRecognition: Bool
    private(set) var startCount = 0
    private var onTranscription: (@MainActor @Sendable ([String], Bool) -> Void)?
    private var onCompletion: (@MainActor @Sendable ((any Error)?) -> Void)?

    init(supportsOnDeviceRecognition: Bool) {
        self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    }

    func requestAuthorization() async -> Bool { true }

    func start(
        onTranscription: @escaping @MainActor @Sendable ([String], Bool) -> Void,
        onCompletion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) throws {
        startCount += 1
        self.onTranscription = onTranscription
        self.onCompletion = onCompletion
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}

    func stop() {
        onTranscription = nil
        onCompletion = nil
    }

    func emit(_ candidates: [String], isFinal: Bool) {
        onTranscription?(candidates, isFinal)
    }

    func complete(error: (any Error)?) {
        onCompletion?(error)
    }
}

private enum WakeTestError: Error {
    case transient
}

@MainActor
private final class WakeTestCapture: VoiceCapturing {
    private(set) var isRecording = false
    private(set) var startCount = 0

    func start(
        autoSubmit: Bool,
        onAutomaticStop: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        isRecording = true
        startCount += 1
    }

    func stop() throws -> CapturedVoice {
        throw VoiceIOError.noSpeech
    }

    func cancel() {
        isRecording = false
    }
}

@MainActor
private final class WakeTestTranscriber: LocalVoiceTranscribing {
    func transcribe(fileURL: URL, language: String) async throws -> String { "" }
}

@MainActor
private final class WakeTestPlayer: VoicePlaying {
    var isPlaying = false
    func playAudio(_ data: Data) async throws {}
    func speakLocally(_ text: String, config: VoiceModeConfiguration.Local) async {}
    func stop() {}
}

@MainActor
private final class WakeTestContextProvider: AssistantContextProviding {
    func context(for window: WorkspaceWindow?) async -> AssistantContext { .empty }
}

private final class WakeTestTransport: SloppyVoiceTransport, @unchecked Sendable {
    private let voiceModeEnabled: Bool

    init(voiceModeEnabled: Bool) {
        self.voiceModeEnabled = voiceModeEnabled
    }

    func health(settings: VoiceAssistantSettingsSnapshot) async throws {}

    func voiceConfiguration(settings: VoiceAssistantSettingsSnapshot) async throws -> VoiceModeConfiguration {
        var configuration = VoiceModeConfiguration.localFallback
        configuration.enabled = voiceModeEnabled
        return configuration
    }

    func agents(settings: VoiceAssistantSettingsSnapshot) async throws -> [SloppyAgentSummary] { [] }

    func transcribe(
        _ request: VoiceTranscriptionRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceTranscriptionResponse {
        throw SloppyTransportError.invalidPayload
    }

    func synthesize(
        _ request: VoiceSpeechRequest,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> VoiceSpeechResponse {
        throw SloppyTransportError.invalidPayload
    }

    func ensureSession(
        agentID: String,
        preferredSessionID: String?,
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> SloppySessionSummary {
        throw SloppyTransportError.invalidPayload
    }

    func postMessage(
        agentID: String,
        sessionID: String,
        content: String,
        attachments: [SloppyAttachmentUpload],
        settings: VoiceAssistantSettingsSnapshot
    ) async throws -> String? {
        throw SloppyTransportError.invalidPayload
    }

    func streamSession(
        agentID: String,
        sessionID: String,
        settings: VoiceAssistantSettingsSnapshot
    ) -> AsyncThrowingStream<SloppyStreamUpdate, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}
