@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class SessionAudioPCMEncoder: @unchecked Sendable {
    private let channelCount: AVAudioChannelCount
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(channelCount: Int) {
        self.channelCount = AVAudioChannelCount(channelCount)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let incomingFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: incomingFormat,
                frameCapacity: frameCount
              ) else { return nil }

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }
        sourceBuffer.frameLength = frameCount

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(SessionAudioConfiguration.sampleRate),
            channels: channelCount,
            interleaved: true
        )!
        let converter = converter(for: incomingFormat, outputFormat: outputFormat)
        let ratio = outputFormat.sampleRate / incomingFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 8
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        let inputProvider = PCMInputProvider(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
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
              outputBuffer.frameLength > 0 else { return nil }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    private func converter(
        for incomingFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) -> AVAudioConverter {
        if sourceFormat != incomingFormat || converter == nil {
            sourceFormat = incomingFormat
            converter = AVAudioConverter(from: incomingFormat, to: outputFormat)
        }
        return converter!
    }
}

private final class PCMInputProvider: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
