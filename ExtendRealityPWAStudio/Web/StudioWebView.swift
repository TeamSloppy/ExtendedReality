import AppKit
import SwiftUI
import WebKit

/// Keeps native AppKit input intact for a PWA panel while reversing trackpad scrolling.
///
/// The web view remains the first responder for the entire pointer sequence, so WebKit
/// receives the original down, drag, and up events as one gesture.
final class StudioInteractiveWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas,
              let copiedEvent = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }

        for field in Self.scrollDeltaFields {
            copiedEvent.setIntegerValueField(
                field,
                value: -copiedEvent.getIntegerValueField(field)
            )
        }

        guard let invertedEvent = NSEvent(cgEvent: copiedEvent) else {
            super.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: invertedEvent)
    }

    private static let scrollDeltaFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1,
        .scrollWheelEventDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis1,
        .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1,
        .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventAcceleratedDeltaAxis1,
        .scrollWheelEventAcceleratedDeltaAxis2,
        .scrollWheelEventRawDeltaAxis1,
        .scrollWheelEventRawDeltaAxis2,
    ]
}

struct StudioWebView: NSViewRepresentable {
    let session: StudioWebSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
