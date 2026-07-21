@preconcurrency import AVFoundation
import Foundation
import Observation

typealias MicrophoneBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

@MainActor
protocol MicrophoneCaptureDriving: AnyObject {
    var isRunning: Bool { get }
    func start(bufferHandler: @escaping MicrophoneBufferHandler) throws
    func stop(deactivateAudioSession: Bool)
}

@MainActor
final class NativeMicrophoneCaptureDriver: MicrophoneCaptureDriving {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    var isRunning: Bool { engine.isRunning }

    func start(bufferHandler: @escaping MicrophoneBufferHandler) throws {
        guard !engine.isRunning else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
        )
        try audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneAudioHubError.inputUnavailable
        }
        // Audio taps run on AVAudioEngine's realtime queue, not the main actor.
        input.installTap(onBus: 0, bufferSize: 960, format: format) { @Sendable buffer, _ in
            bufferHandler(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stop(deactivateAudioSession: Bool) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }
}

@MainActor
@Observable
final class MicrophoneAudioHub {
    private(set) var isCapturing = false
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let driver: any MicrophoneCaptureDriving
    @ObservationIgnored private let permissionRequester: @MainActor () async -> Bool
    @ObservationIgnored private let registry = MicrophoneConsumerRegistry()
    @ObservationIgnored private var consumerIDs: Set<UUID> = []
    @ObservationIgnored private var exclusiveAccessCount = 0
    @ObservationIgnored private var audioSessionRetentionCount = 0
    @ObservationIgnored private var isForegroundActive = false

    init(
        driver: any MicrophoneCaptureDriving = NativeMicrophoneCaptureDriver(),
        permissionRequester: @escaping @MainActor () async -> Bool = MicrophoneAudioHub.requestNativePermission
    ) {
        self.driver = driver
        self.permissionRequester = permissionRequester
    }

    func requestPermission() async -> Bool {
        await permissionRequester()
    }

    private static func requestNativePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    @discardableResult
    func addConsumer(_ handler: @escaping MicrophoneBufferHandler) throws -> UUID {
        let id = registry.add(handler)
        consumerIDs.insert(id)
        do {
            try refreshCapture()
            return id
        } catch {
            consumerIDs.remove(id)
            registry.remove(id)
            throw error
        }
    }

    func removeConsumer(_ id: UUID?) {
        guard let id, consumerIDs.remove(id) != nil else { return }
        registry.remove(id)
        do {
            try refreshCapture()
        } catch {
            report(error)
        }
    }

    func beginExclusiveAccess() -> MicrophoneExclusiveLease {
        exclusiveAccessCount += 1
        if exclusiveAccessCount == 1 {
            registry.setPaused(true)
            driver.stop(deactivateAudioSession: false)
            isCapturing = false
        }
        return MicrophoneExclusiveLease { [weak self] in
            self?.endExclusiveAccess()
        }
    }

    func beginAudioSessionRetention() -> MicrophoneAudioSessionLease {
        audioSessionRetentionCount += 1
        return MicrophoneAudioSessionLease { [weak self] in
            self?.endAudioSessionRetention()
        }
    }

    func setForegroundActive(_ isActive: Bool) {
        guard isForegroundActive != isActive else { return }
        isForegroundActive = isActive
        do {
            try refreshCapture()
        } catch {
            report(error)
        }
    }

    func stop() {
        isForegroundActive = false
        driver.stop(deactivateAudioSession: true)
        isCapturing = false
    }

    private func endExclusiveAccess() {
        guard exclusiveAccessCount > 0 else { return }
        exclusiveAccessCount -= 1
        guard exclusiveAccessCount == 0 else { return }
        registry.setPaused(false)
        do {
            try refreshCapture()
        } catch {
            report(error)
        }
    }

    private func refreshCapture() throws {
        let shouldCapture = isForegroundActive
            && exclusiveAccessCount == 0
            && !consumerIDs.isEmpty
        guard shouldCapture else {
            let shouldDeactivate = !isForegroundActive
                || (exclusiveAccessCount == 0 && audioSessionRetentionCount == 0)
            driver.stop(deactivateAudioSession: shouldDeactivate)
            isCapturing = false
            return
        }
        if !driver.isRunning {
            try driver.start { [registry] buffer in
                registry.deliver(buffer)
            }
        }
        lastErrorMessage = nil
        isCapturing = true
    }

    private func report(_ error: any Error) {
        driver.stop(deactivateAudioSession: audioSessionRetentionCount == 0)
        isCapturing = false
        lastErrorMessage = error.localizedDescription
    }

    private func endAudioSessionRetention() {
        guard audioSessionRetentionCount > 0 else { return }
        audioSessionRetentionCount -= 1
        do {
            try refreshCapture()
        } catch {
            report(error)
        }
    }
}

@MainActor
final class MicrophoneExclusiveLease {
    private var releaseHandler: (() -> Void)?

    init(releaseHandler: @escaping () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        releaseHandler?()
        releaseHandler = nil
    }

    deinit {
        MainActor.assumeIsolated {
            release()
        }
    }
}

@MainActor
final class MicrophoneAudioSessionLease {
    private var releaseHandler: (() -> Void)?

    init(releaseHandler: @escaping () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        releaseHandler?()
        releaseHandler = nil
    }

    deinit {
        MainActor.assumeIsolated {
            release()
        }
    }
}

private final class MicrophoneConsumerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: MicrophoneBufferHandler] = [:]
    private var isPaused = false

    func add(_ handler: @escaping MicrophoneBufferHandler) -> UUID {
        let id = UUID()
        lock.withLock {
            handlers[id] = handler
        }
        return id
    }

    func remove(_ id: UUID) {
        _ = lock.withLock {
            handlers.removeValue(forKey: id)
        }
    }

    func setPaused(_ isPaused: Bool) {
        lock.withLock {
            self.isPaused = isPaused
        }
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        let snapshot = lock.withLock {
            isPaused ? [] : Array(handlers.values)
        }
        for handler in snapshot {
            handler(buffer)
        }
    }
}

enum MicrophoneAudioHubError: LocalizedError {
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "No microphone is available on the current audio route."
        }
    }
}
