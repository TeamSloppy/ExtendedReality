@preconcurrency import Speech

enum SpeechAuthorizationBridge {
    typealias Status = SFSpeechRecognizerAuthorizationStatus
    typealias Requester = @Sendable (@escaping @Sendable (Status) -> Void) -> Void

    nonisolated static func request(
        status: Status = SFSpeechRecognizer.authorizationStatus(),
        requester: @escaping Requester = nativeRequester
    ) async -> Bool {
        switch status {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await withCheckedContinuation(isolation: nil) { continuation in
                requester { @Sendable status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            false
        }
    }

    private nonisolated static func nativeRequester(
        _ completion: @escaping @Sendable (Status) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            completion(status)
        }
    }
}
