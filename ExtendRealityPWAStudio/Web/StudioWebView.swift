import SwiftUI
import WebKit

struct StudioWebView: NSViewRepresentable {
    let session: StudioWebSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
