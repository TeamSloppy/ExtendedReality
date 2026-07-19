import AppKit
import Foundation

struct StudioPackageScript: Identifiable, Equatable {
    let name: String
    let command: String

    var id: String { name }
}

struct StudioProjectInspection: Equatable {
    let packageName: String?
    let scripts: [StudioPackageScript]
    let containsIndexHTML: Bool
}

enum StudioProjectCommand {
    static func fullCommand(directory: URL, command: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return "" }
        return "cd \(shellQuote(directory.path)) && \(trimmedCommand)"
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
final class StudioProjectAccess {
    private enum Keys {
        static let bookmark = "pwaStudio.projectBookmark.v1"
        static let command = "pwaStudio.projectCommand.v1"
    }

    private let defaults: UserDefaults
    private var accessedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var storedCommand: String {
        get { defaults.string(forKey: Keys.command) ?? "" }
        set { defaults.set(newValue, forKey: Keys.command) }
    }

    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a PWA project directory"
        panel.prompt = "Choose"
        panel.message = "Select a directory containing package.json, index.html, or built PWA files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func rememberAndActivate(_ url: URL) throws -> URL {
        stopAccessingCurrentDirectory()
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Keys.bookmark)
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
        return url
    }

    func restoreDirectory() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Keys.bookmark) else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        stopAccessingCurrentDirectory()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
        if isStale {
            _ = try rememberAndActivate(url)
        }
        return url
    }

    func forgetDirectory() {
        stopAccessingCurrentDirectory()
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.command)
    }

    func inspect(_ directory: URL) throws -> StudioProjectInspection {
        let packageURL = directory.appending(path: "package.json")
        let package: PackageDocument?
        if FileManager.default.fileExists(atPath: packageURL.path) {
            let data = try Data(contentsOf: packageURL)
            package = try JSONDecoder().decode(PackageDocument.self, from: data)
        } else {
            package = nil
        }

        let scripts = (package?.scripts ?? [:])
            .map { StudioPackageScript(name: $0.key, command: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let containsIndexHTML = FileManager.default.fileExists(
            atPath: directory.appending(path: "index.html").path
        )
        return StudioProjectInspection(
            packageName: package?.name,
            scripts: scripts,
            containsIndexHTML: containsIndexHTML
        )
    }

    func openInTerminal(_ directory: URL, completion: @escaping (Error?) -> Void) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else {
            completion(StudioProjectAccessError.terminalUnavailable)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminalURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    private func stopAccessingCurrentDirectory() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

private struct PackageDocument: Decodable {
    let name: String?
    let scripts: [String: String]?
}

enum StudioProjectAccessError: LocalizedError {
    case terminalUnavailable

    var errorDescription: String? {
        switch self {
        case .terminalUnavailable: "Terminal.app is unavailable."
        }
    }
}
