import Dispatch
import Speech
import XCTest
@testable import ExtendReality

final class SpeechAuthorizationBridgeTests: XCTestCase {
    func testBackgroundAuthorizationCallbackDoesNotRequireMainActor() async {
        let result = await SpeechAuthorizationBridge.request(
            status: .notDetermined,
            requester: { completion in
                DispatchQueue.global().async {
                    completion(.authorized)
                }
            }
        )

        XCTAssertTrue(result)
    }

    func testKnownAuthorizationStatusDoesNotInvokeRequester() async {
        let requesterWasCalled = ThreadSafeFlag()
        let result = await SpeechAuthorizationBridge.request(
            status: .denied,
            requester: { _ in requesterWasCalled.set() }
        )

        XCTAssertFalse(result)
        XCTAssertFalse(requesterWasCalled.value)
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}
