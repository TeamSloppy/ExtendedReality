import AVFoundation
import Foundation
import Speech

struct CapturedVoice: Sendable, Equatable {
    var data: Data
    var mimeType: String
    var fileURL: URL
}

@MainActor
protocol VoiceCapturing: AnyObject {
    var isRecording: Bool { get }
    func start(
        autoSubmit: Bool,
        onAutomaticStop: @escaping @MainActor @Sendable () -> Void
    ) async throws
    func stop() throws -> CapturedVoice
    func cancel()
}

@MainActor
final class NativeVoiceCapture: NSObject, VoiceCapturing {
    private var recorder: AVAudioRecorder?
    private var monitoringTask: Task<Void, Never>?
    private var fileURL: URL?

    var isRecording: Bool { recorder?.isRecording == true }

    func start(
        autoSubmit: Bool,
        onAutomaticStop: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        cancel()
        guard await requestMicrophonePermission() else {
            throw VoiceIOError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("extend-reality-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let recorder = try AVAudioRecorder(
            url: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        )
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw VoiceIOError.recordingFailed }
        self.fileURL = fileURL
        self.recorder = recorder

        monitoringTask = Task { @MainActor in
            let startedAt = ContinuousClock.now
            var heardVoice = false
            var silenceStartedAt: ContinuousClock.Instant?
            let timeout: Duration = autoSubmit ? .seconds(12) : .seconds(30)

            while !Task.isCancelled, recorder.isRecording {
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                if power > -42 {
                    heardVoice = true
                    silenceStartedAt = nil
                } else if heardVoice, silenceStartedAt == nil {
                    silenceStartedAt = .now
                }

                let timedOut = ContinuousClock.now - startedAt >= timeout
                let completedUtterance = autoSubmit
                    && silenceStartedAt.map { ContinuousClock.now - $0 >= .seconds(1) } == true
                if timedOut || completedUtterance {
                    onAutomaticStop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() throws -> CapturedVoice {
        guard let recorder, let fileURL else { throw VoiceIOError.notRecording }
        monitoringTask?.cancel()
        monitoringTask = nil
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw VoiceIOError.noSpeech }
        return CapturedVoice(data: data, mimeType: "audio/mp4", fileURL: fileURL)
    }

    func cancel() {
        monitoringTask?.cancel()
        monitoringTask = nil
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
protocol LocalVoiceTranscribing: AnyObject {
    func transcribe(fileURL: URL, language: String) async throws -> String
}

@MainActor
final class NativeLocalVoiceTranscriber: LocalVoiceTranscribing {
    func transcribe(fileURL: URL, language: String) async throws -> String {
        guard await requestPermission() else {
            throw VoiceIOError.speechPermissionDenied
        }
        let locale = language == "auto" || language.isEmpty ? Locale.current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceIOError.recognitionUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        continuation.resume(throwing: VoiceIOError.noSpeech)
                    } else {
                        continuation.resume(returning: text)
                    }
                }
            }
            _ = task
        }
    }

    private func requestPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

@MainActor
protocol VoicePlaying: AnyObject {
    var isPlaying: Bool { get }
    func playAudio(_ data: Data) async throws
    func speakLocally(_ text: String, config: VoiceModeConfiguration.Local) async
    func stop()
}

@MainActor
final class NativeVoicePlayer: NSObject, VoicePlaying, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isPlaying: Bool { audioPlayer?.isPlaying == true || synthesizer.isSpeaking }

    func playAudio(_ data: Data) async throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        audioPlayer = player
        var didStart = false
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            didStart = player.play()
            guard didStart else {
                finishPlayback()
                return
            }
        }
        guard didStart else { throw VoiceIOError.playbackFailed }
    }

    func speakLocally(_ text: String, config: VoiceModeConfiguration.Local) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if !config.voiceName.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: config.voiceName)
                ?? AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(config.rate.clamped(to: 0.5 ... 2))
        utterance.pitchMultiplier = Float(config.pitch.clamped(to: 0.5 ... 2))
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finishPlayback()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    private func finishPlayback() {
        audioPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum VoiceIOError: LocalizedError {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recognitionUnavailable
    case recordingFailed
    case playbackFailed
    case notRecording
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone access is required for Voice Mode."
        case .speechPermissionDenied: "Speech recognition access is required for local Voice Mode."
        case .recognitionUnavailable: "Local speech recognition is currently unavailable."
        case .recordingFailed: "Voice recording could not start."
        case .playbackFailed: "The assistant audio could not be played."
        case .notRecording: "Voice Mode is not currently recording."
        case .noSpeech: "No speech was detected."
        }
    }
}
