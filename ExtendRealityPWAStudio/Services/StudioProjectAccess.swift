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

struct StudioProjectIssue: Equatable {
    let title: String
    let reason: String?
    let recoverySuggestion: String?
    let diagnostics: String

    init(error: Error) {
        if let failure = error as? StudioProjectAccessFailure {
            title = failure.errorDescription ?? "The project directory couldn’t be opened."
            reason = failure.failureReason
            recoverySuggestion = failure.recoverySuggestion
            diagnostics = failure.diagnostics
            return
        }

        let cocoaError = error as NSError
        title = cocoaError.localizedDescription
        reason = cocoaError.localizedFailureReason
        recoverySuggestion = cocoaError.localizedRecoverySuggestion
        diagnostics = [
            "System error: \(cocoaError.domain) (\(cocoaError.code))",
            "Description: \(cocoaError.localizedDescription)",
            cocoaError.localizedFailureReason.map { "Reason: \($0)" },
            cocoaError.localizedRecoverySuggestion.map { "Suggestion: \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
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
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw StudioProjectAccessFailure(
                operation: .saveBookmark,
                url: url,
                underlyingError: error
            )
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw StudioProjectAccessFailure(operation: .activateAccess, url: url)
        }

        stopAccessingCurrentDirectory()
        defaults.set(bookmark, forKey: Keys.bookmark)
        accessedURL = url
        return url
    }

    func restoreDirectory() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Keys.bookmark) else { return nil }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw StudioProjectAccessFailure(
                operation: .restoreBookmark,
                url: nil,
                underlyingError: error
            )
        }

        if isStale {
            return try rememberAndActivate(url)
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw StudioProjectAccessFailure(operation: .activateAccess, url: url)
        }
        stopAccessingCurrentDirectory()
        accessedURL = url
        return url
    }

    func forgetDirectory() {
        stopAccessingCurrentDirectory()
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.command)
    }

    func inspect(_ directory: URL) throws -> StudioProjectInspection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw StudioProjectAccessFailure(operation: .validateDirectory, url: directory)
        }
        guard FileManager.default.isReadableFile(atPath: directory.path) else {
            throw StudioProjectAccessFailure(operation: .activateAccess, url: directory)
        }

        let packageURL = directory.appending(path: "package.json")
        let package: PackageDocument?
        if FileManager.default.fileExists(atPath: packageURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: packageURL)
            } catch {
                throw StudioProjectAccessFailure(
                    operation: .readPackageManifest,
                    url: packageURL,
                    underlyingError: error
                )
            }
            do {
                package = try JSONDecoder().decode(PackageDocument.self, from: data)
            } catch {
                throw StudioProjectAccessFailure(
                    operation: .decodePackageManifest,
                    url: packageURL,
                    underlyingError: error
                )
            }
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

    func openInTerminal(
        _ directory: URL,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
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

enum StudioProjectAccessOperation: String, Equatable {
    case saveBookmark = "Save directory access"
    case restoreBookmark = "Restore saved directory access"
    case activateAccess = "Activate sandbox access"
    case validateDirectory = "Validate project directory"
    case readPackageManifest = "Read package.json"
    case decodePackageManifest = "Parse package.json"

    fileprivate func errorDescription(for url: URL?) -> String {
        let name = url?.lastPathComponent
        switch self {
        case .saveBookmark:
            return name.map { "Couldn’t remember access to “\($0)”." }
                ?? "Couldn’t remember access to the project directory."
        case .restoreBookmark:
            return "Couldn’t restore access to the saved project directory."
        case .activateAccess:
            return name.map { "Access to “\($0)” wasn’t granted." }
                ?? "Access to the project directory wasn’t granted."
        case .validateDirectory:
            return name.map { "“\($0)” is no longer an available directory." }
                ?? "The saved project directory is no longer available."
        case .readPackageManifest:
            return "Couldn’t read package.json."
        case .decodePackageManifest:
            return "Couldn’t parse package.json."
        }
    }

    fileprivate var fallbackReason: String {
        switch self {
        case .saveBookmark:
            "macOS couldn’t create a persistent, read-only security bookmark for this directory."
        case .restoreBookmark:
            "The saved security bookmark is invalid, stale, or no longer resolves to a directory."
        case .activateAccess:
            "The App Sandbox did not grant read access to this directory."
        case .validateDirectory:
            "The path doesn’t exist, isn’t a directory, or can’t be reached with the current sandbox permission."
        case .readPackageManifest:
            "PWA Studio found package.json but macOS did not allow it to be read."
        case .decodePackageManifest:
            "package.json isn’t valid JSON or contains scripts in an unsupported format."
        }
    }

    fileprivate var recoverySuggestion: String {
        switch self {
        case .saveBookmark, .activateAccess:
            "Choose the directory again. If it is on an external or cloud volume, make sure it is mounted and fully downloaded."
        case .restoreBookmark, .validateDirectory:
            "Forget the saved directory and choose its current location again."
        case .readPackageManifest:
            "Check the file permissions, then choose the directory again."
        case .decodePackageManifest:
            "Fix package.json and choose the directory again."
        }
    }
}

struct StudioProjectAccessFailure: LocalizedError {
    let operation: StudioProjectAccessOperation
    let url: URL?
    private let underlyingError: NSError?

    init(operation: StudioProjectAccessOperation, url: URL?, underlyingError: Error? = nil) {
        self.operation = operation
        self.url = url
        self.underlyingError = underlyingError.map { $0 as NSError }
    }

    var errorDescription: String? {
        operation.errorDescription(for: url)
    }

    var failureReason: String? {
        guard let systemReason = underlyingError?.localizedFailureReason else {
            return operation.fallbackReason
        }
        return "\(operation.fallbackReason) macOS reported: \(systemReason)"
    }

    var recoverySuggestion: String? {
        underlyingError?.localizedRecoverySuggestion ?? operation.recoverySuggestion
    }

    var diagnostics: String {
        var lines = ["Operation: \(operation.rawValue)"]
        if let url {
            lines.append("Path: \(url.path)")
        }
        if let underlyingError {
            lines.append("System error: \(underlyingError.domain) (\(underlyingError.code))")
            lines.append("Description: \(underlyingError.localizedDescription)")
            if let failureReason = underlyingError.localizedFailureReason {
                lines.append("Reason: \(failureReason)")
            }
            if let recoverySuggestion = underlyingError.localizedRecoverySuggestion {
                lines.append("System suggestion: \(recoverySuggestion)")
            }
        } else {
            lines.append("Reason: \(operation.fallbackReason)")
        }
        lines.append("Suggestion: \(operation.recoverySuggestion)")
        return lines.joined(separator: "\n")
    }
}
