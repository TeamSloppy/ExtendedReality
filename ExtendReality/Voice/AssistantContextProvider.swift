import CoreGraphics
import Foundation
import UIKit
import WebKit

@MainActor
protocol AssistantContextProviding: AnyObject {
    func context(for window: WorkspaceWindow?) async -> AssistantContext
}

extension SurfaceRegistry: AssistantContextProviding {
    func context(for window: WorkspaceWindow?) async -> AssistantContext {
        guard let window else { return .empty }
        let cursor = inputRouter.surfaceCursorPosition(in: window.id)

        switch window.source {
        case .browser:
            return await webContext(
                session: browser(for: window.id),
                title: window.title,
                kind: "browser",
                cursor: cursor
            )
        case .pwa(let installation, let displayMode):
            return await webContext(
                session: pwa(for: window.id, installation: installation, displayMode: displayMode),
                title: window.title,
                kind: "pwa",
                cursor: cursor
            )
        case .youtube:
            let session = youtubeSession(for: window.id)
            return AssistantContext(
                surfaceTitle: window.title,
                surfaceKind: "youtube",
                url: session.videoID.map { "https://www.youtube.com/watch?v=\($0)" },
                focusedText: nil,
                screenshotJPEG: await Self.snapshotJPEG(of: session.webView)
            )
        case .gallery:
            let session = mediaSession(for: window.id)
            return AssistantContext(
                surfaceTitle: session.fileName ?? window.title,
                surfaceKind: session.isVideo ? "video" : "image",
                url: nil,
                focusedText: nil,
                screenshotJPEG: session.image.flatMap(Self.compressedJPEG)
            )
        case .remoteDesktop(let host):
            if let host, Self.isWebStreamAddress(host) {
                return await webContext(
                    session: macStream(for: window.id, initialURL: host),
                    title: window.title,
                    kind: "mac_stream",
                    cursor: cursor
                )
            }
            let session = remoteDesktop(for: window.id, initialHost: host)
            return AssistantContext(
                surfaceTitle: window.title,
                surfaceKind: "remote_desktop",
                url: nil,
                focusedText: nil,
                screenshotJPEG: session.framebuffer.map(UIImage.init(cgImage:)).flatMap(Self.compressedJPEG)
            )
        }
    }

    private func webContext(
        session: BrowserSession,
        title: String,
        kind: String,
        cursor: CGPoint
    ) async -> AssistantContext {
        AssistantContext(
            surfaceTitle: session.title.isEmpty ? title : session.title,
            surfaceKind: kind,
            url: session.address,
            focusedText: await session.focusedText(at: cursor),
            screenshotJPEG: await Self.snapshotJPEG(of: session.webView)
        )
    }

    private static func snapshotJPEG(of webView: WKWebView) async -> Data? {
        guard webView.bounds.width > 1, webView.bounds.height > 1 else { return nil }
        return await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.afterScreenUpdates = false
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image.flatMap(compressedJPEG))
            }
        }
    }

    static func compressedJPEG(_ image: UIImage) -> Data? {
        let maxDimension: CGFloat = 1_280
        let sourceSize = image.size
        let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height, 1))
        let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let rendered: UIImage
        if scale < 1 {
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            rendered = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        } else {
            rendered = image
        }

        for quality in stride(from: CGFloat(0.78), through: 0.34, by: -0.11) {
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= 1_000_000 {
                return data
            }
        }
        return rendered.jpegData(compressionQuality: 0.25)
    }
}

extension BrowserSession {
    func focusedText(at position: CGPoint) async -> String? {
        let x = position.x.clamped(to: 0 ... 1)
        let y = position.y.clamped(to: 0 ... 1)
        let script = """
            (() => {
              const element = document.elementFromPoint(
                Math.round(window.innerWidth * \(x)),
                Math.round(window.innerHeight * \(y))
              );
              if (!element) return '';
              const labelled = element.getAttribute('aria-label') || element.getAttribute('alt') || '';
              const text = labelled || element.innerText || element.textContent || '';
              return String(text).replace(/\\s+/g, ' ').trim().slice(0, 600);
            })();
            """
        guard let value = try? await webView.evaluateJavaScript(script) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
