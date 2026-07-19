import Foundation
import Observation

enum VoiceAssistantPhase: String, Sendable, Equatable {
    case idle
    case listening
    case transcribing
    case preview
    case awaitingAgent
    case speaking
    case error
    case cancelled

    var isPresented: Bool {
        self != .idle && self != .cancelled
    }
}

struct VoiceAssistantState: Sendable, Equatable {
    var phase: VoiceAssistantPhase = .idle
    var statusText = ""
    var transcript = ""
    var responseText = ""
    var agentName = "Sloppy"
    var pet: SloppyAgentPet?

    static let idle = VoiceAssistantState()
}

struct VoiceAssistantSettingsSnapshot: Sendable, Equatable {
    var isEnabled: Bool
    var coreURL: URL
    var dashboardURL: URL
    var authToken: String
    var agentID: String
    var sharesActiveContext: Bool
}

@MainActor
@Observable
final class VoiceAssistantSettings {
    private enum Key {
        static let enabled = "voiceAssistant.enabled"
        static let coreURL = "voiceAssistant.coreURL"
        static let dashboardURL = "voiceAssistant.dashboardURL"
        static let agentID = "voiceAssistant.agentID"
        static let sharesContext = "voiceAssistant.sharesActiveContext"
        static let token = "voiceAssistant.sloppyToken"
        static let configured = "voiceAssistant.configured"
    }

    var isEnabled: Bool { didSet { save() } }
    var coreURLString: String { didSet { save() } }
    var dashboardURLString: String { didSet { save() } }
    var agentID: String { didSet { save() } }
    var sharesActiveContext: Bool { didSet { save() } }
    var authToken: String {
        didSet {
            if authToken.isEmpty {
                keychain.delete(account: Key.token)
            } else {
                try? keychain.setString(authToken, for: Key.token)
            }
        }
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private var isLoading = true

    init(defaults: UserDefaults = .standard, keychain: KeychainStore) {
        self.defaults = defaults
        self.keychain = keychain
        let configured = defaults.bool(forKey: Key.configured)
        isEnabled = configured ? defaults.bool(forKey: Key.enabled) : true
        coreURLString = defaults.string(forKey: Key.coreURL) ?? "http://localhost:25101"
        dashboardURLString = defaults.string(forKey: Key.dashboardURL) ?? "http://localhost:25102"
        agentID = defaults.string(forKey: Key.agentID) ?? "sloppy"
        sharesActiveContext = configured ? defaults.bool(forKey: Key.sharesContext) : true
        authToken = keychain.string(for: Key.token) ?? ""
        isLoading = false
    }

    var snapshot: VoiceAssistantSettingsSnapshot? {
        guard let coreURL = normalizedURL(coreURLString),
              let dashboardURL = normalizedURL(dashboardURLString),
              !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return VoiceAssistantSettingsSnapshot(
            isEnabled: isEnabled,
            coreURL: coreURL,
            dashboardURL: dashboardURL,
            authToken: authToken.trimmingCharacters(in: .whitespacesAndNewlines),
            agentID: agentID.trimmingCharacters(in: .whitespacesAndNewlines),
            sharesActiveContext: sharesActiveContext
        )
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(true, forKey: Key.configured)
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(coreURLString, forKey: Key.coreURL)
        defaults.set(dashboardURLString, forKey: Key.dashboardURL)
        defaults.set(agentID, forKey: Key.agentID)
        defaults.set(sharesActiveContext, forKey: Key.sharesContext)
    }

    private func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}

struct VoiceModeConfiguration: Codable, Sendable, Equatable {
    struct Input: Codable, Sendable, Equatable {
        var mode: String
        var language: String
        var previewBeforeSend: Bool
    }

    struct Local: Codable, Sendable, Equatable {
        var enabled: Bool
        var voiceName: String
        var rate: Double
        var pitch: Double
    }

    var enabled: Bool
    var effectiveProvider: String
    var localAvailable: Bool
    var input: Input
    var local: Local

    static let localFallback = VoiceModeConfiguration(
        enabled: true,
        effectiveProvider: "local",
        localAvailable: true,
        input: .init(mode: "push_to_talk", language: "auto", previewBeforeSend: true),
        local: .init(enabled: true, voiceName: "", rate: 1, pitch: 1)
    )
}

struct VoiceTranscriptionRequest: Codable, Sendable, Equatable {
    var audioBase64: String
    var mimeType: String
    var language: String?
    var prompt: String?
}

struct VoiceTranscriptionResponse: Codable, Sendable, Equatable {
    var text: String
    var provider: String
    var model: String
}

struct VoiceSpeechRequest: Codable, Sendable, Equatable {
    var text: String
    var voice: String?
    var instructions: String?
}

struct VoiceSpeechResponse: Codable, Sendable, Equatable {
    var audioBase64: String
    var mimeType: String
    var provider: String
    var model: String
    var voice: String
}

struct SloppyAgentSummary: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var pet: SloppyAgentPet?
}

struct SloppyAgentPet: Codable, Sendable, Equatable {
    struct Visual: Codable, Sendable, Equatable {
        var displayName: String
        var currentStage: Int
    }

    struct StageAsset: Codable, Sendable, Equatable {
        var stage: Int
        var spriteSheetPath: String
        var stateFrameRanges: [String: FrameRange]
    }

    struct FrameRange: Codable, Sendable, Equatable {
        var start: Int
        var end: Int
        var fps: Double
        var loop: Bool
    }

    var visual: Visual?
    var stageAssets: [StageAsset]
}

struct SloppySessionSummary: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var agentId: String
    var title: String
}

struct SloppyAttachmentUpload: Codable, Sendable, Equatable {
    var name: String
    var mimeType: String
    var sizeBytes: Int
    var contentBase64: String?
}

struct AssistantContext: Sendable, Equatable {
    var surfaceTitle: String
    var surfaceKind: String
    var url: String?
    var focusedText: String?
    var screenshotJPEG: Data?

    static let empty = AssistantContext(surfaceTitle: "Workspace", surfaceKind: "workspace")

    var promptBlock: String {
        var lines = [
            "[ExtendReality voice context]",
            "Active surface: \(surfaceTitle)",
            "Surface kind: \(surfaceKind)",
        ]
        if let url, !url.isEmpty { lines.append("URL: \(url)") }
        if let focusedText, !focusedText.isEmpty { lines.append("Focused content: \(focusedText)") }
        if screenshotJPEG != nil { lines.append("A screenshot of the active surface is attached.") }
        lines.append("Answer concisely in plain text suitable for speech.")
        return lines.joined(separator: "\n")
    }

    var attachment: SloppyAttachmentUpload? {
        guard let screenshotJPEG else { return nil }
        return SloppyAttachmentUpload(
            name: "extend-reality-context.jpg",
            mimeType: "image/jpeg",
            sizeBytes: screenshotJPEG.count,
            contentBase64: screenshotJPEG.base64EncodedString()
        )
    }
}

enum SloppyStreamUpdate: Sendable, Equatable {
    case ready
    case delta(String)
    case assistantMessage(String)
    case error(String)
    case closed
}
