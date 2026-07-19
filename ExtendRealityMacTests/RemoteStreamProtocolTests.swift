import CoreGraphics
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
                    url: URL(string: "http://mac.local:52799/")!,
                    width: 3_840,
                    height: 1_080
                )
            ],
            cursorURL: URL(string: "http://mac.local:52799/api/v1/cursor")
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RemoteStreamSession.self, from: data)

        #expect(decoded == session)
    }

    @Test
    func streamGeometryMatchesCaptureAndUltrawideCanvas() {
        let displays = [
            CaptureDisplay(id: 1, name: "Left", width: 3_840, height: 2_160),
            CaptureDisplay(id: 2, name: "Right", width: 1_920, height: 1_080),
        ]

        #expect(StreamGeometry.captureSize(width: 3_840, height: 2_160) == CGSize(width: 2_560, height: 1_440))
        #expect(StreamGeometry.primarySize(layout: .single, displays: displays) == CGSize(width: 2_560, height: 1_440))
        #expect(StreamGeometry.primarySize(layout: .ultrawide, displays: displays) == CGSize(width: 4_480, height: 1_440))
    }

    @Test
    func cursorGeometrySelectsTheCorrectMultipleDisplay() throws {
        let displays = [
            CaptureDisplay(id: 1, name: "Left", width: 100, height: 100),
            CaptureDisplay(id: 2, name: "Right", width: 100, height: 100),
        ]
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            2: CGRect(x: 100, y: 0, width: 100, height: 100),
        ]

        let position = CursorStreamGeometry.position(
            cursor: CGPoint(x: 150, y: 25),
            layout: .multiple,
            displays: displays,
            displayBounds: bounds
        )

        #expect(position.visible)
        #expect(position.streamID == "2")
        #expect(try #require(position.x) == 0.5)
        #expect(try #require(position.y) == 0.25)
    }

    @Test
    func cursorGeometryMapsDisplaysIntoUltrawideCanvas() throws {
        let displays = [
            CaptureDisplay(id: 1, name: "Left", width: 100, height: 100),
            CaptureDisplay(id: 2, name: "Right", width: 100, height: 100),
        ]
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            2: CGRect(x: 100, y: 0, width: 100, height: 100),
        ]

        let position = CursorStreamGeometry.position(
            cursor: CGPoint(x: 150, y: 25),
            layout: .ultrawide,
            displays: displays,
            displayBounds: bounds
        )

        #expect(position.visible)
        #expect(position.streamID == "primary")
        #expect(try #require(position.x) == 0.75)
        #expect(try #require(position.y) == 0.25)
    }

    @Test
    func cursorGeometryHidesPositionOutsideStreamedDisplays() {
        let displays = [CaptureDisplay(id: 1, name: "Primary", width: 100, height: 100)]
        let position = CursorStreamGeometry.position(
            cursor: CGPoint(x: 200, y: 200),
            layout: .single,
            displays: displays,
            displayBounds: [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
        )

        #expect(position == .hidden)
    }
}
