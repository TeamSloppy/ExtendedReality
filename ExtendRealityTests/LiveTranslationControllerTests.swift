import AVFoundation
import XCTest
@testable import ExtendReality

@MainActor
final class LiveTranslationControllerTests: XCTestCase {
    func testLanguagePairPersistsAndSwaps() {
        let defaults = makeDefaults()
        let controller = makeController(defaults: defaults)
        controller.sourceLanguage = .russian
        controller.targetLanguage = .english

        controller.swapLanguages()

        XCTAssertEqual(controller.sourceLanguage, .english)
        XCTAssertEqual(controller.targetLanguage, .russian)
        let restored = makeController(defaults: defaults)
        XCTAssertEqual(restored.sourceLanguage, .english)
        XCTAssertEqual(restored.targetLanguage, .russian)
    }

    func testStartAndStopUseOnlyOnDeviceRecognizer() async {
        let defaults = makeDefaults()
        let recognizer = FakeLiveSpeechRecognizer()
        let driver = FakeMicrophoneCaptureDriver()
        let hub = MicrophoneAudioHub(driver: driver, permissionRequester: { true })
        hub.setForegroundActive(true)
        let controller = LiveTranslationController(
            audioHub: hub,
            defaults: defaults,
            recognizerFactory: { _ in recognizer }
        )
        var listeningChanges: [Bool] = []
        controller.onListeningChange = { listeningChanges.append($0) }

        await controller.start()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(recognizer.didStart)
        XCTAssertTrue(driver.isRunning)
        XCTAssertEqual(listeningChanges, [true])

        controller.stop()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(listeningChanges, [true, false])
    }

    func testUnsupportedLocalRecognitionFailsWithoutOpeningMicrophone() async {
        let defaults = makeDefaults()
        let recognizer = FakeLiveSpeechRecognizer()
        recognizer.supportsOnDeviceRecognition = false
        let driver = FakeMicrophoneCaptureDriver()
        let hub = MicrophoneAudioHub(driver: driver, permissionRequester: { true })
        let controller = LiveTranslationController(
            audioHub: hub,
            defaults: defaults,
            recognizerFactory: { _ in recognizer }
        )

        await controller.start()

        guard case .failed(let message) = controller.state else {
            return XCTFail("Expected an unavailable on-device model error")
        }
        XCTAssertTrue(message.contains("On-device"))
        XCTAssertFalse(recognizer.didStart)
        XCTAssertFalse(driver.isRunning)
    }

    private func makeController(defaults: UserDefaults) -> LiveTranslationController {
        let hub = MicrophoneAudioHub(
            driver: FakeMicrophoneCaptureDriver(),
            permissionRequester: { true }
        )
        return LiveTranslationController(
            audioHub: hub,
            defaults: defaults,
            recognizerFactory: { _ in FakeLiveSpeechRecognizer() }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "LiveTranslationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class FakeLiveSpeechRecognizer: LiveSpeechRecognizing, @unchecked Sendable {
    var supportsOnDeviceRecognition = true
    var didStart = false

    func requestAuthorization() async -> Bool { true }

    func start(
        onTranscription: @escaping @MainActor @Sendable (String, Bool) -> Void,
        onCompletion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) throws {
        didStart = true
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}

    func stop() {}
}

@MainActor
private final class FakeMicrophoneCaptureDriver: MicrophoneCaptureDriving {
    private(set) var isRunning = false

    func start(bufferHandler: @escaping MicrophoneBufferHandler) throws {
        isRunning = true
    }

    func stop(deactivateAudioSession: Bool) {
        isRunning = false
    }
}
