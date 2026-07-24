import Foundation
import Testing
@testable import ExtendReality

struct ExtendRealityFocusProfileTests {
    @Test
    func focusSelectionRoundTripsThroughSharedStorageFormat() throws {
        let suiteName = "ExtendRealityFocusProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let selection = ExtendRealityFocusSelection(
            profile: .deepWork,
            updatedAt: Date(timeIntervalSince1970: 1_234)
        )

        ExtendRealityFocusStorage.save(selection, defaults: defaults)

        #expect(ExtendRealityFocusStorage.load(defaults: defaults) == selection)
    }

    @Test
    func missingSelectionHasNoActiveProfile() throws {
        let suiteName = "ExtendRealityFocusProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ExtendRealityFocusStorage.load(defaults: defaults) == nil)
    }
}
