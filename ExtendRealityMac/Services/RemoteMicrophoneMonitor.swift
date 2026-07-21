@preconcurrency import AVFoundation
import Foundation

@MainActor
final class RemoteMicrophoneMonitor {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(SessionAudioConfiguration.sampleRate),
        channels: AVAudioChannelCount(SessionAudioConfiguration.microphoneChannels)
    )!
    private var pendingBytes = Data()

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func consume(_ data: Data) {
        pendingBytes.append(data)
        let bytesPerFrame = MemoryLayout<Int16>.size * SessionAudioConfiguration.microphoneChannels
        let frameCount = pendingBytes.count / bytesPerFrame
        guard frameCount > 0 else { return }

        let byteCount = frameCount * bytesPerFrame
        let chunk = pendingBytes.prefix(byteCount)
        pendingBytes.removeFirst(byteCount)

        guard startIfNeeded(),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let samples = buffer.floatChannelData?[0] else { return }

        chunk.withUnsafeBytes { rawBuffer in
            for index in 0 ..< frameCount {
                let sample = rawBuffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Int16>.size,
                    as: Int16.self
                )
                samples[index] = Float(Int16(littleEndian: sample)) / Float(Int16.max)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        pendingBytes.removeAll(keepingCapacity: true)
    }

    private func startIfNeeded() -> Bool {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return false
            }
        }
        return true
    }
}
