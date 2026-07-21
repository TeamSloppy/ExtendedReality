@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

enum WakeWordState: Equatable, Sendable {
    case disabled
    case starting
    case listening
    case suspended
    case unavailable(message: String, opensSystemSettings: Bool)

    var statusText: String {
        switch self {
        case .disabled: "Wake word is off"
        case .starting: "Starting wake-word detection…"
        case .listening: "Listening for “Sloppy”"
        case .suspended: "Wake word paused while Sloppy is active"
        case .unavailable(let message, _): message
        }
    }

    var systemImage: String {
        switch self {
        case .listening: "waveform.badge.mic"
        case .starting: "waveform"
        case .suspended: "pause.circle"
        case .unavailable: "exclamationmark.triangle.fill"
        case .disabled: "mic.slash"
        }
    }

    var isListening: Bool {
        self == .listening
    }

    var opensSystemSettings: Bool {
        if case .unavailable(_, let opensSystemSettings) = self {
            return opensSystemSettings
        }
        return false
    }
}

@MainActor
protocol WakeWordRecognizing: AnyObject, Sendable {
    var supportsOnDeviceRecognition: Bool { get }
    func requestAuthorization() async -> Bool
    func start(
        onTranscription: @escaping @MainActor @Sendable (_ candidates: [String], _ isFinal: Bool) -> Void,
        onCompletion: @escaping @MainActor @Sendable (_ error: (any Error)?) -> Void
    ) throws
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

@MainActor
final class NativeWakeWordRecognizer: WakeWordRecognizing {
    private let recognizer: SFSpeechRecognizer?
    private let audioSink = SpeechAudioRequestSink()
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = .current) {
        let locales = [locale, Locale(identifier: "en_US")]
        recognizer = locales.lazy
            .compactMap(SFSpeechRecognizer.init(locale:))
            .first(where: \.supportsOnDeviceRecognition)
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition == true
    }

    func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            false
        }
    }

    func start(
        onTranscription: @escaping @MainActor @Sendable ([String], Bool) -> Void,
        onCompletion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) throws {
        stop()
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw WakeWordError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = ["Sloppy", "Слоппи", "Слопи"]
        request.taskHint = .search
        audioSink.setRequest(request)
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let candidates = result.transcriptions.map(\.formattedString)
                Task { @MainActor in
                    onTranscription(candidates, result.isFinal)
                    if result.isFinal {
                        onCompletion(nil)
                    }
                }
            } else if let error {
                Task { @MainActor in
                    onCompletion(error)
                }
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        audioSink.append(buffer)
    }

    func stop() {
        audioSink.clearRequest()
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}

@MainActor
@Observable
final class WakeWordController {
    private(set) var state: WakeWordState = .disabled

    @ObservationIgnored private let settings: VoiceAssistantSettings
    @ObservationIgnored private let assistant: VoiceAssistantCoordinator
    @ObservationIgnored private let microphoneHub: MicrophoneAudioHub
    @ObservationIgnored private let recognizer: any WakeWordRecognizing
    @ObservationIgnored private var microphoneConsumerID: UUID?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var consecutiveWakeResults = 0
    @ObservationIgnored private var restartDelay: Duration = .milliseconds(500)
    @ObservationIgnored private var isForegroundActive = false

    init(
        settings: VoiceAssistantSettings,
        assistant: VoiceAssistantCoordinator,
        microphoneHub: MicrophoneAudioHub,
        recognizer: any WakeWordRecognizing = NativeWakeWordRecognizer()
    ) {
        self.settings = settings
        self.assistant = assistant
        self.microphoneHub = microphoneHub
        self.recognizer = recognizer
    }

    func setForegroundActive(_ isActive: Bool) {
        isForegroundActive = isActive
        microphoneHub.setForegroundActive(isActive)
        reevaluate(resumeDelay: false)
    }

    func configurationDidChange() {
        reevaluate(resumeDelay: false)
    }

    func assistantStateDidChange() {
        reevaluate(resumeDelay: !assistant.state.phase.suppressesWakeWord)
    }

    private var isEligible: Bool {
        isForegroundActive
            && settings.isEnabled
            && settings.wakeWordEnabled
            && !assistant.state.phase.suppressesWakeWord
    }

    private func reevaluate(resumeDelay: Bool) {
        guard isEligible else {
            stopRecognition()
            if !settings.isEnabled || !settings.wakeWordEnabled {
                state = .disabled
            } else {
                state = .suspended
            }
            return
        }

        if state.isListening || state == .starting { return }
        scheduleStart(after: resumeDelay ? .milliseconds(750) : .zero)
    }

    private func scheduleStart(after delay: Duration) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.prepareAndStart()
        }
    }

    private func prepareAndStart() async {
        guard isEligible else { return }
        preparationTask?.cancel()
        let currentGeneration = generation
        state = .starting
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard recognizer.supportsOnDeviceRecognition else {
                markUnavailable(
                    "On-device wake-word recognition is unavailable for this device or language.",
                    opensSystemSettings: false
                )
                return
            }
            guard await microphoneHub.requestPermission() else {
                markUnavailable(
                    "Microphone access is required to listen for “Sloppy”.",
                    opensSystemSettings: true
                )
                return
            }
            guard await recognizer.requestAuthorization() else {
                markUnavailable(
                    "Speech Recognition access is required to detect “Sloppy” on device.",
                    opensSystemSettings: true
                )
                return
            }
            guard !Task.isCancelled, generation == currentGeneration, isEligible else { return }
            do {
                try startRecognition()
            } catch {
                markUnavailable(error.localizedDescription, opensSystemSettings: false)
            }
        }
        await preparationTask?.value
    }

    private func startRecognition() throws {
        recognizer.stop()
        consecutiveWakeResults = 0
        try recognizer.start(
            onTranscription: { [weak self] candidates, isFinal in
                self?.handle(candidates: candidates, isFinal: isFinal)
            },
            onCompletion: { [weak self] error in
                self?.recognitionDidComplete(error: error)
            }
        )
        do {
            microphoneConsumerID = try microphoneHub.addConsumer { [recognizer] buffer in
                recognizer.append(buffer)
            }
        } catch {
            recognizer.stop()
            throw error
        }
        restartDelay = .milliseconds(500)
        state = .listening
    }

    private func handle(candidates: [String], isFinal: Bool) {
        guard state.isListening, isEligible else { return }
        let containsWakeWord = candidates.contains(where: WakeWordMatcher.containsWakeWord)
        if containsWakeWord {
            consecutiveWakeResults += 1
        } else {
            consecutiveWakeResults = 0
        }
        guard containsWakeWord, isFinal || consecutiveWakeResults >= 2 else { return }

        stopRecognition()
        state = .suspended
        assistant.activate()
    }

    private func recognitionDidComplete(error: (any Error)?) {
        guard state.isListening else { return }
        recognizer.stop()
        microphoneHub.removeConsumer(microphoneConsumerID)
        microphoneConsumerID = nil
        consecutiveWakeResults = 0
        guard isEligible else {
            reevaluate(resumeDelay: false)
            return
        }
        state = .starting
        let delay = error == nil ? Duration.milliseconds(500) : restartDelay
        if error != nil {
            restartDelay = min(restartDelay * 2, .seconds(8))
        }
        scheduleStart(after: delay)
    }

    private func stopRecognition() {
        generation += 1
        preparationTask?.cancel()
        preparationTask = nil
        restartTask?.cancel()
        restartTask = nil
        recognizer.stop()
        microphoneHub.removeConsumer(microphoneConsumerID)
        microphoneConsumerID = nil
        consecutiveWakeResults = 0
    }

    private func markUnavailable(_ message: String, opensSystemSettings: Bool) {
        stopRecognition()
        settings.wakeWordEnabled = false
        state = .unavailable(message: message, opensSystemSettings: opensSystemSettings)
    }
}

enum WakeWordMatcher {
    private static let aliases: Set<String> = ["sloppy", "слоппи", "слопи"]

    static func containsWakeWord(_ transcription: String) -> Bool {
        normalizedTokens(in: transcription).contains(where: aliases.contains)
    }

    private static func normalizedTokens(in value: String) -> [String] {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

private final class SpeechAudioRequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock {
            self.request = request
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            request?.append(buffer)
        }
    }

    func clearRequest() {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }
}

enum WakeWordError: LocalizedError {
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .onDeviceRecognitionUnavailable:
            "On-device wake-word recognition is unavailable."
        }
    }
}
