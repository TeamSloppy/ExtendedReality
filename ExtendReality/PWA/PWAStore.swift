import Foundation
import Observation

enum PWACatalogState: Equatable {
    case idle
    case loading
    case loaded(Date)
    case notConfigured
    case failed(String)
}

struct PWACatalogClient: Sendable {
    var fetch: @Sendable (URL) async throws -> Data

    static let live = PWACatalogClient { url in
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              200 ..< 300 ~= response.statusCode else {
            throw PWACatalogClientError.invalidResponse
        }
        return data
    }
}

enum PWACatalogClientError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "The PWA catalog returned an invalid response." }
}

@MainActor
@Observable
final class PWAStore {
    private(set) var catalog: [PWAAppManifest] = []
    private(set) var installations: [PWAInstallation]
    private(set) var catalogState: PWACatalogState = .idle
    private(set) var declaredAge: Int?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let declaredAgeKey: String
    @ObservationIgnored private let catalogURL: URL?
    @ObservationIgnored private let client: PWACatalogClient
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "pwa.installations.v1",
        declaredAgeKey: String = "pwa.declaredAge.v1",
        catalogURL: URL? = PWAStore.configuredCatalogURL,
        client: PWACatalogClient = .live
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.declaredAgeKey = declaredAgeKey
        self.catalogURL = catalogURL
        self.client = client
        if let data = defaults.data(forKey: storageKey),
           let restored = try? decoder.decode([PWAInstallation].self, from: data) {
            installations = restored
        } else {
            installations = []
        }
        declaredAge = defaults.object(forKey: declaredAgeKey) as? Int
    }

    var catalogEndpoint: URL? { catalogURL }

    func refresh() async {
        guard let catalogURL else {
            catalogState = .notConfigured
            catalog = []
            return
        }

        catalogState = .loading
        do {
            let data = try await client.fetch(catalogURL)
            try Task.checkCancellation()
            let document = try decoder.decode(PWACatalogDocument.self, from: data)
            catalog = try document.validatedApps()
            catalogState = .loaded(.now)
        } catch is CancellationError {
            return
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    func installation(for appID: String) -> PWAInstallation? {
        installations.first(where: { $0.id == appID })
    }

    func isInstalled(_ appID: String) -> Bool {
        installation(for: appID) != nil
    }

    func isAllowedForDeclaredAge(_ manifest: PWAAppManifest) -> Bool {
        manifest.minimumAge <= 4 || (declaredAge ?? 0) >= manifest.minimumAge
    }

    func setDeclaredAge(_ age: Int?) {
        declaredAge = age
        if let age {
            defaults.set(age, forKey: declaredAgeKey)
        } else {
            defaults.removeObject(forKey: declaredAgeKey)
        }
    }

    @discardableResult
    func install(
        _ manifest: PWAAppManifest,
        grantedCapabilities: Set<PWACapability>
    ) throws -> PWAInstallation {
        try manifest.validate()
        guard isAllowedForDeclaredAge(manifest) else {
            throw PWAValidationError.ageRestricted(manifest.id, requiredAge: manifest.minimumAge)
        }
        let requested = Set(manifest.requestedCapabilities)
        guard grantedCapabilities.isSubset(of: requested) else {
            throw PWAValidationError.unrequestedCapability(
                grantedCapabilities.subtracting(requested).first!
            )
        }

        if let existing = installation(for: manifest.id) {
            return existing
        }

        let installation = PWAInstallation(
            manifest: manifest,
            installedAt: .now,
            dataStoreIdentifier: UUID(),
            grantedCapabilities: grantedCapabilities
        )
        installations.append(installation)
        save()
        return installation
    }

    @discardableResult
    func uninstall(_ appID: String) -> PWAInstallation? {
        guard let index = installations.firstIndex(where: { $0.id == appID }) else { return nil }
        let installation = installations.remove(at: index)
        save()
        return installation
    }

    func setCapability(_ capability: PWACapability, granted: Bool, for appID: String) throws {
        guard let index = installations.firstIndex(where: { $0.id == appID }) else { return }
        let requested = Set(installations[index].manifest.requestedCapabilities)
        guard requested.contains(capability) else {
            throw PWAValidationError.unrequestedCapability(capability)
        }
        if granted {
            installations[index].grantedCapabilities.insert(capability)
        } else {
            installations[index].grantedCapabilities.remove(capability)
        }
        save()
    }

    private func save() {
        guard let data = try? encoder.encode(installations) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static var configuredCatalogURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ExtendRealityPWACatalogURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }
}
