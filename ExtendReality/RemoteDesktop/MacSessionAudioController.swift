@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Network
import Observation

enum MacSessionAudioState: Equatable, Sendable {
    case inactive
    case connecting
    case active
    case playbackOnly
    case failed(String)

    var statusText: String? {
        switch self {
        case .inactive: nil
        case .connecting: "Connecting session audio…"
        case .active: "Glasses audio and microphone are active"
        case .playbackOnly: "Glasses audio is active · microphone access is off"
        case .failed(let message): "Session audio: \(message)"
        }
    }
}

@MainActor
@Observable
final class MacSessionAudioController {
    private(set) var state: MacSessionAudioState = .inactive

    @ObservationIgnored private let microphoneHub: MicrophoneAudioHub
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(SessionAudioConfiguration.sampleRate),
        channels: AVAudioChannelCount(SessionAudioConfiguration.playbackChannels)
    )!
    @ObservationIgnored private let networkQueue = DispatchQueue(
        label: "com.vladprusakov.ExtendReality.session-audio",
        qos: .userInteractive
    )
    @ObservationIgnored private var playbackConnection: NWConnection?
    @ObservationIgnored private var microphoneConnection: NWConnection?
    @ObservationIgnored private var playbackBytes = Data()
    @ObservationIgnored private var microphoneConsumerID: UUID?
    @ObservationIgnored private var audioSessionRetention: MicrophoneAudioSessionLease?
    @ObservationIgnored private var playbackReady = false
    @ObservationIgnored private var microphoneReady = false
    @ObservationIgnored private var microphoneGranted = false

    init(microphoneHub: MicrophoneAudioHub = MicrophoneAudioHub()) {
        self.microphoneHub = microphoneHub
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }

    func start(_ configuration: SessionAudioConfiguration) async {
        stop()
        guard configuration.isSupported else {
            state = .failed("The Mac advertised an unsupported format.")
            return
        }
        state = .connecting
        audioSessionRetention = microphoneHub.beginAudioSessionRetention()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
            )
            try audioSession.setPreferredSampleRate(Double(configuration.sampleRate))
            try audioSession.setPreferredIOBufferDuration(0.02)
            try audioSession.setActive(true)

            microphoneGranted = await requestMicrophonePermission()
            try engine.start()
            player.play()
            try connectPlayback(to: configuration.playbackURL)
            if microphoneGranted {
                try connectMicrophone(to: configuration.microphoneURL)
            }
            refreshState()
        } catch {
            stop()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        playbackConnection?.cancel()
        microphoneConnection?.cancel()
        playbackConnection = nil
        microphoneConnection = nil
        playbackReady = false
        microphoneReady = false
        microphoneGranted = false
        microphoneHub.removeConsumer(microphoneConsumerID)
        microphoneConsumerID = nil
        player.stop()
        engine.stop()
        playbackBytes.removeAll(keepingCapacity: true)
        audioSessionRetention?.release()
        audioSessionRetention = nil
        state = .inactive
    }

    private func connectPlayback(to url: URL) throws {
        let connection = try makeConnection(for: url)
        playbackConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.playbackConnection === connection else { return }
                switch connectionState {
                case .ready:
                    self.playbackReady = true
                    self.refreshState()
                    let request = "GET \(url.path) HTTP/1.1\r\nHost: \(url.host ?? "localhost")\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .idempotent)
                    self.receivePlaybackHeaders(on: connection, accumulated: Data())
                case .failed(let error):
                    self.fail(error)
                case .cancelled:
                    self.fail(SessionAudioError.connectionClosed)
                default:
                    break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    private func connectMicrophone(to url: URL) throws {
        let connection = try makeConnection(for: url)
        microphoneConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.microphoneConnection === connection else { return }
                switch connectionState {
                case .ready:
                    let request = "POST \(url.path) HTTP/1.1\r\nHost: \(url.host ?? "localhost")\r\nContent-Type: application/x-extendreality-pcm\r\nX-Audio-Sample-Rate: \(SessionAudioConfiguration.sampleRate)\r\nX-Audio-Channels: \(SessionAudioConfiguration.microphoneChannels)\r\nX-Audio-Sample-Format: s16le\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .idempotent)
                    self.microphoneReady = true
                    do {
                        try self.installMicrophoneConsumer(sendingTo: connection)
                    } catch {
                        self.fail(error)
                        return
                    }
                    self.refreshState()
                case .failed(let error):
                    self.fail(error)
                case .cancelled:
                    self.fail(SessionAudioError.connectionClosed)
                default:
                    break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    private func makeConnection(for url: URL) throws -> NWConnection {
        guard let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw SessionAudioError.invalidEndpoint
        }
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    private func receivePlaybackHeaders(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.playbackConnection === connection else { return }
                if let error {
                    self.fail(error)
                    return
                }
                var response = accumulated
                if let data { response.append(data) }
                let separator = Data("\r\n\r\n".utf8)
                guard let headerRange = response.range(of: separator) else {
                    if isComplete || response.count > 65_536 {
                        self.fail(SessionAudioError.invalidResponse)
                    } else {
                        self.receivePlaybackHeaders(on: connection, accumulated: response)
                    }
                    return
                }
                let header = String(decoding: response[..<headerRange.lowerBound], as: UTF8.self)
                guard header.hasPrefix("HTTP/1.1 200") else {
                    self.fail(SessionAudioError.invalidResponse)
                    return
                }
                self.consumePlaybackPCM(Data(response[headerRange.upperBound...]))
                self.receivePlaybackPCM(on: connection)
            }
        }
    }

    private func receivePlaybackPCM(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.playbackConnection === connection else { return }
                if let data, !data.isEmpty {
                    self.consumePlaybackPCM(data)
                }
                if let error {
                    self.fail(error)
                } else if isComplete {
                    self.fail(SessionAudioError.connectionClosed)
                } else {
                    self.receivePlaybackPCM(on: connection)
                }
            }
        }
    }

    private func consumePlaybackPCM(_ data: Data) {
        playbackBytes.append(data)
        let channelCount = SessionAudioConfiguration.playbackChannels
        let bytesPerFrame = MemoryLayout<Int16>.size * channelCount
        let frameCount = playbackBytes.count / bytesPerFrame
        guard frameCount > 0 else { return }

        let byteCount = frameCount * bytesPerFrame
        let chunk = playbackBytes.prefix(byteCount)
        playbackBytes.removeFirst(byteCount)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else { return }

        chunk.withUnsafeBytes { rawBuffer in
            for frame in 0 ..< frameCount {
                for channel in 0 ..< channelCount {
                    let offset = (frame * channelCount + channel) * MemoryLayout<Int16>.size
                    let sample = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                    channels[channel][frame] = Float(Int16(littleEndian: sample)) / Float(Int16.max)
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            player.play()
        }
    }

    private func installMicrophoneConsumer(sendingTo connection: NWConnection) throws {
        guard microphoneConsumerID == nil else { return }
        let encoder = MicrophonePCMEncoder()
        microphoneConsumerID = try microphoneHub.addConsumer { buffer in
            guard let pcm = encoder.encode(buffer), !pcm.isEmpty else { return }
            connection.send(content: pcm, completion: .idempotent)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await microphoneHub.requestPermission()
    }

    private func refreshState() {
        guard state != .inactive else { return }
        if playbackReady, microphoneReady {
            state = .active
        } else if playbackReady, !microphoneGranted {
            state = .playbackOnly
        } else {
            state = .connecting
        }
    }

    private func fail(_ error: any Error) {
        let message = error.localizedDescription
        stop()
        state = .failed(message)
    }
}

private final class MicrophonePCMEncoder: @unchecked Sendable {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(SessionAudioConfiguration.sampleRate),
        channels: AVAudioChannelCount(SessionAudioConfiguration.microphoneChannels),
        interleaved: true
    )!
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func encode(_ input: AVAudioPCMBuffer) -> Data? {
        let converter = converter(for: input.format)
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let inputProvider = MicrophoneInputProvider(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputProvider.wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputProvider.wasSupplied = true
            inputStatus.pointee = .haveData
            return inputProvider.buffer
        }
        guard conversionError == nil,
              status == .haveData || status == .inputRanDry,
              output.frameLength > 0 else { return nil }

        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    private func converter(for format: AVAudioFormat) -> AVAudioConverter {
        if inputFormat != format || converter == nil {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }
        return converter!
    }
}

private final class MicrophoneInputProvider: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private enum SessionAudioError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case microphoneUnavailable
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The session advertised an invalid audio endpoint."
        case .invalidResponse: "The Mac returned an invalid audio response."
        case .microphoneUnavailable: "No microphone is available on the current audio route."
        case .connectionClosed: "The Mac closed the audio connection."
        }
    }
}
