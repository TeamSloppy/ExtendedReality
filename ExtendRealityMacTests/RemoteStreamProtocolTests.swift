import Foundation
import Testing
@testable import ExtendRealityMac

struct RemoteStreamProtocolTests {
    @Test
    func streamSessionRoundTripsThroughJSON() throws {
        let session = RemoteStreamSession(
            version: 1,
            layout: .ultrawide,
            streams: [
                RemoteStreamEndpoint(
                    id: "primary",
                    name: "Mac Ultrawide",
                    url: URL(string: "http://mac.local:52799/")!
                )
            ]
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RemoteStreamSession.self, from: data)

        #expect(decoded == session)
    }
}
