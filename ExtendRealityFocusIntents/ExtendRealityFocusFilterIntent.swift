import AppIntents
import Foundation

struct ExtendRealityFocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Configure ExtendReality Focus"
    static let description = IntentDescription(
        "Choose the ExtendReality profile that becomes active with this system Focus."
    )

    @Parameter(title: "Profile")
    var profile: ExtendRealityFocusProfile?

    static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$profile)")
    }

    var displayRepresentation: DisplayRepresentation {
        if let profile {
            return DisplayRepresentation(
                title: "\(profile.title)",
                subtitle: "ExtendReality profile",
                image: .init(systemName: profile.systemImage)
            )
        }
        return DisplayRepresentation(
            title: "No ExtendReality profile",
            image: .init(systemName: "moon")
        )
    }

    func perform() async throws -> some IntentResult {
        ExtendRealityFocusStorage.save(
            ExtendRealityFocusSelection(profile: profile, updatedAt: .now)
        )
        return .result()
    }
}

@main
struct ExtendRealityFocusIntentsExtension: AppIntentsExtension {}
