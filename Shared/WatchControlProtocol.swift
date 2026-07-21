import Foundation

enum WatchControlCommand: Equatable, Sendable {
    case pointerDelta(x: Double, y: Double)
    case scroll(delta: Double)
    case click
    case recenter
    case focusWindow(id: UUID)
    case openWindow(kind: String)
    case minimizeWindow(id: UUID)
    case closeWindow(id: UUID)
    case back
    case togglePlayback
    case seekPlayback(seconds: Double)
    case toggleVoiceAssistant
    case requestState

    private enum Key {
        static let command = "command"
        static let x = "x"
        static let y = "y"
        static let delta = "delta"
        static let id = "id"
        static let kind = "kind"
    }

    init?(dictionary: [String: Any]) {
        guard let rawCommand = dictionary[Key.command] as? String else { return nil }
        switch rawCommand {
        case "pointerDelta":
            guard let x = dictionary[Key.x] as? Double,
                  let y = dictionary[Key.y] as? Double else { return nil }
            self = .pointerDelta(x: x, y: y)
        case "scroll":
            guard let delta = dictionary[Key.delta] as? Double else { return nil }
            self = .scroll(delta: delta)
        case "click":
            self = .click
        case "recenter":
            self = .recenter
        case "focusWindow", "minimizeWindow", "closeWindow":
            guard let rawID = dictionary[Key.id] as? String,
                  let id = UUID(uuidString: rawID) else { return nil }
            switch rawCommand {
            case "focusWindow": self = .focusWindow(id: id)
            case "minimizeWindow": self = .minimizeWindow(id: id)
            default: self = .closeWindow(id: id)
            }
        case "openWindow":
            guard let kind = dictionary[Key.kind] as? String else { return nil }
            self = .openWindow(kind: kind)
        case "back":
            self = .back
        case "togglePlayback":
            self = .togglePlayback
        case "seekPlayback":
            guard let seconds = dictionary[Key.delta] as? Double else { return nil }
            self = .seekPlayback(seconds: seconds)
        case "toggleVoiceAssistant":
            self = .toggleVoiceAssistant
        case "requestState":
            self = .requestState
        default:
            return nil
        }
    }

    var dictionary: [String: Any] {
        switch self {
        case .pointerDelta(let x, let y):
            [Key.command: "pointerDelta", Key.x: x, Key.y: y]
        case .scroll(let delta):
            [Key.command: "scroll", Key.delta: delta]
        case .click:
            [Key.command: "click"]
        case .recenter:
            [Key.command: "recenter"]
        case .focusWindow(let id):
            [Key.command: "focusWindow", Key.id: id.uuidString]
        case .openWindow(let kind):
            [Key.command: "openWindow", Key.kind: kind]
        case .minimizeWindow(let id):
            [Key.command: "minimizeWindow", Key.id: id.uuidString]
        case .closeWindow(let id):
            [Key.command: "closeWindow", Key.id: id.uuidString]
        case .back:
            [Key.command: "back"]
        case .togglePlayback:
            [Key.command: "togglePlayback"]
        case .seekPlayback(let seconds):
            [Key.command: "seekPlayback", Key.delta: seconds]
        case .toggleVoiceAssistant:
            [Key.command: "toggleVoiceAssistant"]
        case .requestState:
            [Key.command: "requestState"]
        }
    }
}

struct WatchPlaybackState: Equatable, Sendable {
    let windowID: UUID
    let isPlaying: Bool

    init(windowID: UUID, isPlaying: Bool) {
        self.windowID = windowID
        self.isPlaying = isPlaying
    }

    init?(dictionary: [String: Any]) {
        guard let rawWindowID = dictionary["windowID"] as? String,
              let windowID = UUID(uuidString: rawWindowID),
              let isPlaying = dictionary["isPlaying"] as? Bool else { return nil }
        self.init(windowID: windowID, isPlaying: isPlaying)
    }

    var dictionary: [String: Any] {
        [
            "windowID": windowID.uuidString,
            "isPlaying": isPlaying
        ]
    }
}

struct WatchWindowSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let kind: String
    let isMinimized: Bool

    init(id: UUID, title: String, kind: String, isMinimized: Bool) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isMinimized = isMinimized
    }

    init?(dictionary: [String: Any]) {
        guard let rawID = dictionary["id"] as? String,
              let id = UUID(uuidString: rawID),
              let title = dictionary["title"] as? String,
              let kind = dictionary["kind"] as? String,
              let isMinimized = dictionary["isMinimized"] as? Bool else { return nil }
        self.init(id: id, title: title, kind: kind, isMinimized: isMinimized)
    }

    var dictionary: [String: Any] {
        [
            "id": id.uuidString,
            "title": title,
            "kind": kind,
            "isMinimized": isMinimized
        ]
    }
}

struct WatchWorkspaceSnapshot: Equatable, Sendable {
    let activeWindowID: UUID?
    let windows: [WatchWindowSummary]
    let trackingStatus: String
    let isTracking: Bool
    let voiceAssistantPhase: String
    let playback: WatchPlaybackState?

    init(
        activeWindowID: UUID?,
        windows: [WatchWindowSummary],
        trackingStatus: String,
        isTracking: Bool,
        voiceAssistantPhase: String = "idle",
        playback: WatchPlaybackState? = nil
    ) {
        self.activeWindowID = activeWindowID
        self.windows = windows
        self.trackingStatus = trackingStatus
        self.isTracking = isTracking
        self.voiceAssistantPhase = voiceAssistantPhase
        self.playback = playback
    }

    init?(dictionary: [String: Any]) {
        guard let rawWindows = dictionary["windows"] as? [[String: Any]],
              let trackingStatus = dictionary["trackingStatus"] as? String,
              let isTracking = dictionary["isTracking"] as? Bool else { return nil }
        let windows = rawWindows.compactMap(WatchWindowSummary.init(dictionary:))
        guard windows.count == rawWindows.count else { return nil }
        let rawActiveID = dictionary["activeWindowID"] as? String
        self.init(
            activeWindowID: rawActiveID.flatMap(UUID.init(uuidString:)),
            windows: windows,
            trackingStatus: trackingStatus,
            isTracking: isTracking,
            voiceAssistantPhase: dictionary["voiceAssistantPhase"] as? String ?? "idle",
            playback: (dictionary["playback"] as? [String: Any]).flatMap(WatchPlaybackState.init(dictionary:))
        )
    }

    var dictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "activeWindowID": activeWindowID?.uuidString ?? "",
            "windows": windows.map(\.dictionary),
            "trackingStatus": trackingStatus,
            "isTracking": isTracking,
            "voiceAssistantPhase": voiceAssistantPhase
        ]
        if let playback {
            dictionary["playback"] = playback.dictionary
        }
        return dictionary
    }
}
