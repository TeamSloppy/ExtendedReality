import AppIntents
import Foundation
import Observation

@MainActor
@Observable
final class VoiceModeActivationRouter {
    struct Request: Equatable, Sendable {
        let id: UUID
    }

    static let shared = VoiceModeActivationRouter()

    private(set) var pendingRequest: Request?

    func requestActivation() {
        pendingRequest = Request(id: UUID())
    }

    func consume(_ requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        pendingRequest = nil
    }
}

struct StartSloppyVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Sloppy Voice Mode"
    static let description = IntentDescription(
        "Open ExtendReality and start listening for a request to Sloppy Assistant."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            VoiceModeActivationRouter.shared.requestActivation()
        }
        return .result(dialog: "Starting Sloppy Voice Mode.")
    }
}

struct ExtendRealityAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSloppyVoiceModeIntent(),
            phrases: [
                "Start Sloppy in \(.applicationName)",
                "Talk to Sloppy in \(.applicationName)",
                "Open voice mode in \(.applicationName)",
            ],
            shortTitle: "Start Sloppy",
            systemImageName: "waveform.circle.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .purple }
}
