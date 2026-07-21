import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await importSharedRoute() }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Adding route to ExtendReality…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func importSharedRoute() async {
        guard let route = await sharedRouteValue(), Self.isAppleMapsRoute(route),
              let deepLink = Self.deepLink(for: route) else {
            showError("Share a place or route from Apple Maps.")
            return
        }

        guard let extensionContext else { return }
        let didOpen = await extensionContext.open(deepLink)
        if didOpen {
            extensionContext.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            showError("Could not open ExtendReality. Open the app once, then try again.")
        }
    }

    private func sharedRouteValue() async -> String? {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments) ?? [])
            .flatMap { $0 }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
               let value = Self.string(from: item) {
                return value
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
               let value = Self.string(from: item) {
                return value
            }
        }
        return nil
    }

    private func showError(_ message: String) {
        statusLabel.text = message
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Close",
            style: .done,
            target: self,
            action: #selector(close)
        )
    }

    @objc private func close() {
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: "ExtendRealityMapsShare",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: statusLabel.text ?? "Unable to import route"]
            )
        )
    }

    private static func string(from item: NSSecureCoding) -> String? {
        switch item {
        case let url as URL: url.absoluteString
        case let url as NSURL: (url as URL).absoluteString
        case let string as String: string
        case let string as NSString: string as String
        default: nil
        }
    }

    private static func isAppleMapsRoute(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return false }
        return host == "maps.apple.com" || host.hasSuffix(".maps.apple.com") || host.hasSuffix("maps.apple")
    }

    private static func deepLink(for route: String) -> URL? {
        var components = URLComponents()
        components.scheme = "extendreality"
        components.host = "maps"
        components.path = "/import"
        components.queryItems = [URLQueryItem(name: "route", value: route)]
        return components.url
    }
}
