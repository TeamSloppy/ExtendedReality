@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech
import Translation

enum LiveTranslationLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en-US"
    case russian = "ru-RU"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case italian = "it-IT"
    case portuguese = "pt-BR"
    case chinese = "zh-CN"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    var shortTitle: String {
        Locale(identifier: rawValue).language.languageCode?.identifier.uppercased() ?? rawValue
    }

    var locale: Locale { Locale(identifier: rawValue) }

    var translationLanguage: Locale.Language {
        Locale.Language(identifier: locale.language.languageCode?.identifier ?? rawValue)
    }

    static func defaultSource(for locale: Locale = .current) -> Self {
        let languageCode = locale.language.languageCode?.identifier
        return allCases.first {
            $0.locale.language.languageCode?.identifier == languageCode
        } ?? .english
    }
}

enum LiveTranslationState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .listening: true
        case .idle, .failed: false
        }
    }
}

private struct LiveTranslationRequest: Sendable {
    let id: Int
    let text: String
    let source: LiveTranslationLanguage
    let target: LiveTranslationLanguage
}

@MainActor
protocol LiveSpeechRecognizing: AnyObject, Sendable {
    var supportsOnDeviceRecognition: Bool { get }
    func requestAuthorization() async -> Bool
    func start(
        onTranscription: @escaping @MainActor @Sendable (_ text: String, _ isFinal: Bool) -> Void,
        onCompletion: @escaping @MainActor @Sendable (_ error: (any Error)?) -> Void
    ) throws
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

@MainActor
final class NativeLiveSpeechRecognizer: LiveSpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?
    private let audioSink = LiveSpeechAudioRequestSink()
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition == true
    }

    func requestAuthorization() async -> Bool {
        await SpeechAuthorizationBridge.request()
    }

    func start(
        onTranscription: @escaping @MainActor @Sendable (String, Bool) -> Void,
        onCompletion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) throws {
        stop()
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw LiveTranslationError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        audioSink.setRequest(request)
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    onTranscription(text, result.isFinal)
                    if result.isFinal {
                        onCompletion(nil)
                    }
                }
            } else if let error {
                Task { @MainActor in onCompletion(error) }
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
final class LiveTranslationController {
    private(set) var state: LiveTranslationState = .idle
    private(set) var sourceText = ""
    private(set) var translatedText = ""
    private(set) var isTranslating = false

    var sourceLanguage: LiveTranslationLanguage {
        didSet {
            guard sourceLanguage != oldValue, !isUpdatingLanguages else { return }
            languageSelectionDidChange()
        }
    }
    var targetLanguage: LiveTranslationLanguage {
        didSet {
            guard targetLanguage != oldValue, !isUpdatingLanguages else { return }
            languageSelectionDidChange()
        }
    }
    var onListeningChange: ((Bool) -> Void)?

    @ObservationIgnored private let audioHub: MicrophoneAudioHub
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recognizerFactory: @MainActor (Locale) -> any LiveSpeechRecognizing
    @ObservationIgnored private let requestStream: AsyncStream<LiveTranslationRequest>
    @ObservationIgnored private let requestContinuation: AsyncStream<LiveTranslationRequest>.Continuation
    @ObservationIgnored private var recognizer: (any LiveSpeechRecognizing)?
    @ObservationIgnored private var microphoneConsumerID: UUID?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var translationDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var isUpdatingLanguages = false

    private static let sourceDefaultsKey = "liveTranslation.sourceLanguage"
    private static let targetDefaultsKey = "liveTranslation.targetLanguage"

    init(
        audioHub: MicrophoneAudioHub,
        defaults: UserDefaults = .standard,
        recognizerFactory: @escaping @MainActor (Locale) -> any LiveSpeechRecognizing = {
            NativeLiveSpeechRecognizer(locale: $0)
        }
    ) {
        self.audioHub = audioHub
        self.defaults = defaults
        self.recognizerFactory = recognizerFactory

        let defaultSource = LiveTranslationLanguage.defaultSource()
        sourceLanguage = defaults.string(forKey: Self.sourceDefaultsKey)
            .flatMap(LiveTranslationLanguage.init(rawValue:)) ?? defaultSource
        targetLanguage = defaults.string(forKey: Self.targetDefaultsKey)
            .flatMap(LiveTranslationLanguage.init(rawValue:)) ?? (defaultSource == .english ? .spanish : .english)

        let stream = AsyncStream.makeStream(
            of: LiveTranslationRequest.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        requestStream = stream.stream
        requestContinuation = stream.continuation
    }

    var languagePairLabel: String {
        "\(sourceLanguage.shortTitle) → \(targetLanguage.shortTitle)"
    }

    var statusText: String {
        switch state {
        case .idle:
            "Tap to start local subtitles"
        case .starting:
            "Preparing on-device recognition…"
        case .listening where isTranslating:
            "Translating on device…"
        case .listening:
            "Listening on device"
        case .failed(let message):
            message
        }
    }

    func toggle() async {
        if state.isActive {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        stop(notify: false)
        generation += 1
        let currentGeneration = generation
        state = .starting

        let recognizer = recognizerFactory(sourceLanguage.locale)
        guard recognizer.supportsOnDeviceRecognition else {
            fail(LiveTranslationError.onDeviceRecognitionUnavailable.localizedDescription)
            return
        }
        guard await audioHub.requestPermission() else {
            fail(LiveTranslationError.microphonePermissionDenied.localizedDescription)
            return
        }
        guard await recognizer.requestAuthorization() else {
            fail(LiveTranslationError.speechPermissionDenied.localizedDescription)
            return
        }
        guard !Task.isCancelled, generation == currentGeneration else { return }

        self.recognizer = recognizer
        onListeningChange?(true)
        do {
            try beginRecognition(using: recognizer, generation: currentGeneration)
            state = .listening
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        stop(notify: true)
    }

    func swapLanguages() {
        let source = sourceLanguage
        isUpdatingLanguages = true
        sourceLanguage = targetLanguage
        targetLanguage = source
        isUpdatingLanguages = false
        languageSelectionDidChange()
    }

    func consumeTranslations(using session: sending TranslationSession) async {
        for await request in requestStream {
            guard !Task.isCancelled else { return }
            guard request.source == sourceLanguage, request.target == targetLanguage else { continue }
            isTranslating = true
            do {
                let response = try await session.translate(request.text)
                guard !Task.isCancelled,
                      request.id == requestID,
                      request.source == sourceLanguage,
                      request.target == targetLanguage else { continue }
                translatedText = response.targetText
                isTranslating = false
            } catch is CancellationError {
                isTranslating = false
                return
            } catch {
                isTranslating = false
                if state.isActive {
                    state = .failed("Translation model unavailable: \(error.localizedDescription)")
                    stopCapture(notify: true)
                }
            }
        }
    }

    private func beginRecognition(
        using recognizer: any LiveSpeechRecognizing,
        generation: Int
    ) throws {
        try recognizer.start(
            onTranscription: { [weak self] text, isFinal in
                self?.handleTranscription(text, isFinal: isFinal)
            },
            onCompletion: { [weak self] error in
                self?.recognitionDidComplete(error: error, generation: generation)
            }
        )
        do {
            microphoneConsumerID = try audioHub.addConsumer { [recognizer] buffer in
                recognizer.append(buffer)
            }
        } catch {
            recognizer.stop()
            throw error
        }
    }

    private func handleTranscription(_ text: String, isFinal: Bool) {
        guard state.isActive else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sourceText = trimmed
        requestID += 1
        let request = LiveTranslationRequest(
            id: requestID,
            text: trimmed,
            source: sourceLanguage,
            target: targetLanguage
        )
        translationDebounceTask?.cancel()
        translationDebounceTask = Task { @MainActor [weak self] in
            if !isFinal {
                try? await Task.sleep(for: .milliseconds(280))
            }
            guard !Task.isCancelled else { return }
            self?.requestContinuation.yield(request)
        }
    }

    private func recognitionDidComplete(error: (any Error)?, generation: Int) {
        guard state.isActive, generation == self.generation else { return }
        recognizer?.stop()
        audioHub.removeConsumer(microphoneConsumerID)
        microphoneConsumerID = nil
        state = .starting

        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(error == nil ? 180 : 650))
            guard !Task.isCancelled,
                  let self,
                  self.generation == generation,
                  let recognizer = self.recognizer else { return }
            do {
                try self.beginRecognition(using: recognizer, generation: generation)
                self.state = .listening
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func languageSelectionDidChange() {
        defaults.set(sourceLanguage.rawValue, forKey: Self.sourceDefaultsKey)
        defaults.set(targetLanguage.rawValue, forKey: Self.targetDefaultsKey)
        sourceText = ""
        translatedText = ""
        requestID += 1
        guard state.isActive else { return }
        Task { @MainActor [weak self] in
            self?.stop()
            await self?.start()
        }
    }

    private func stop(notify: Bool) {
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        translationDebounceTask?.cancel()
        translationDebounceTask = nil
        stopCapture(notify: notify)
        isTranslating = false
        state = .idle
    }

    private func stopCapture(notify: Bool) {
        recognizer?.stop()
        recognizer = nil
        audioHub.removeConsumer(microphoneConsumerID)
        microphoneConsumerID = nil
        if notify {
            onListeningChange?(false)
        }
    }

    private func fail(_ message: String) {
        stopCapture(notify: true)
        isTranslating = false
        state = .failed(message)
    }
}

private final class LiveSpeechAudioRequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    func clearRequest() {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }
}

enum LiveTranslationError: LocalizedError {
    case microphonePermissionDenied
    case speechPermissionDenied
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required for live subtitles."
        case .speechPermissionDenied:
            "Speech Recognition access is required for local subtitles."
        case .onDeviceRecognitionUnavailable:
            "On-device speech recognition is not installed for this language."
        }
    }
}
