import CoreLocation
import Foundation
import HealthKit
import Intents
import Observation
import UIKit

enum SystemDataAuthorization: String, Codable, Sendable {
    case notDetermined
    case requested
    case restricted
    case denied
    case authorized
    case unavailable

    var title: String {
        switch self {
        case .notDetermined: "Not requested"
        case .requested: "Access requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .unavailable: "Unavailable"
        }
    }
}

struct DeviceLocationData: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let timestamp: Date
}

struct HealthSummaryData: Codable, Equatable, Sendable {
    let steps: Int
    let activeEnergyKilocalories: Double
    let latestHeartRateBPM: Double?
    let updatedAt: Date
}

enum SystemDataError: LocalizedError, Equatable {
    case permissionRequired(PWACapability)
    case dataUnavailable(PWACapability)
    case healthDataUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired(let capability):
            "Enable \(capability.title) access in ExtendReality Settings first."
        case .dataUnavailable(let capability):
            "\(capability.title) data is not available yet."
        case .healthDataUnavailable:
            "Health data is not available on this device."
        }
    }
}

@MainActor
@Observable
final class SystemDataStore: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var locationAuthorization: SystemDataAuthorization = .notDetermined
    private(set) var healthAuthorization: SystemDataAuthorization = .notDetermined
    private(set) var focusAuthorization: SystemDataAuthorization = .notDetermined
    private(set) var location: DeviceLocationData?
    private(set) var healthSummary: HealthSummaryData?
    private(set) var isFocused: Bool?
    private(set) var focusUpdatedAt: Date?
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let locationManager: CLLocationManager
    @ObservationIgnored private let healthStore: HKHealthStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let healthRequestKey: String
    @ObservationIgnored private let loadsSystemData: Bool

    init(
        defaults: UserDefaults = .standard,
        healthRequestKey: String = "systemData.healthAuthorizationRequested.v1",
        loadsSystemData: Bool = true
    ) {
        self.defaults = defaults
        self.healthRequestKey = healthRequestKey
        self.loadsSystemData = loadsSystemData
        locationManager = CLLocationManager()
        healthStore = HKHealthStore()
        super.init()

        guard loadsSystemData else {
            locationAuthorization = .unavailable
            healthAuthorization = .unavailable
            focusAuthorization = .unavailable
            return
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        healthAuthorization = HKHealthStore.isHealthDataAvailable()
            ? (defaults.bool(forKey: healthRequestKey) ? .requested : .notDetermined)
            : .unavailable
        refreshLocationAuthorization()
        refreshFocusStatus()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        if locationAuthorization == .authorized {
            locationManager.requestLocation()
        }
        if healthAuthorization == .requested || healthAuthorization == .authorized {
            Task { await refreshHealth() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func requestLocationAccess() {
        guard loadsSystemData else { return }
        lastErrorMessage = nil
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .denied:
            locationAuthorization = .denied
        case .restricted:
            locationAuthorization = .restricted
        @unknown default:
            locationAuthorization = .unavailable
        }
    }

    func requestHealthAccess() async {
        guard loadsSystemData, HKHealthStore.isHealthDataAvailable() else {
            healthAuthorization = .unavailable
            lastErrorMessage = SystemDataError.healthDataUnavailable.localizedDescription
            return
        }

        lastErrorMessage = nil
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.healthReadTypes)
            defaults.set(true, forKey: healthRequestKey)
            // HealthKit intentionally doesn't reveal whether individual read permissions
            // were denied. A successful request means the authorization flow completed.
            healthAuthorization = .requested
            await refreshHealth()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func requestFocusAccess() {
        guard loadsSystemData else { return }
        lastErrorMessage = nil
        INFocusStatusCenter.default.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.focusAuthorization = Self.focusAuthorization(from: status)
                self.refreshFocusStatus()
            }
        }
    }

    func refreshAll() async {
        guard loadsSystemData else { return }
        refreshLocationAuthorization()
        if locationAuthorization == .authorized {
            locationManager.requestLocation()
        }
        if healthAuthorization == .requested || healthAuthorization == .authorized {
            await refreshHealth()
        }
        refreshFocusStatus()
    }

    func refreshHealth() async {
        guard loadsSystemData, HKHealthStore.isHealthDataAvailable() else { return }
        do {
            async let steps = cumulativeQuantity(
                identifier: .stepCount,
                unit: .count()
            )
            async let energy = cumulativeQuantity(
                identifier: .activeEnergyBurned,
                unit: .kilocalorie()
            )
            async let heartRate = latestQuantity(
                identifier: .heartRate,
                unit: HKUnit.count().unitDivided(by: .minute())
            )
            healthSummary = try await HealthSummaryData(
                steps: Int(steps.rounded()),
                activeEnergyKilocalories: energy,
                latestHeartRateBPM: heartRate,
                updatedAt: .now
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshFocusStatus() {
        guard loadsSystemData else { return }
        let center = INFocusStatusCenter.default
        focusAuthorization = Self.focusAuthorization(from: center.authorizationStatus)
        isFocused = focusAuthorization == .authorized ? center.focusStatus.isFocused : nil
        focusUpdatedAt = .now
    }

    func pwaPayload(for capability: PWACapability) throws -> [String: Any] {
        switch capability {
        case .location:
            guard locationAuthorization == .authorized else {
                throw SystemDataError.permissionRequired(capability)
            }
            guard let location else { throw SystemDataError.dataUnavailable(capability) }
            return [
                "latitude": location.latitude,
                "longitude": location.longitude,
                "horizontalAccuracy": location.horizontalAccuracy,
                "timestamp": Self.iso8601.string(from: location.timestamp),
            ]
        case .health:
            guard healthAuthorization == .requested || healthAuthorization == .authorized else {
                throw SystemDataError.permissionRequired(capability)
            }
            guard let healthSummary else { throw SystemDataError.dataUnavailable(capability) }
            var payload: [String: Any] = [
                "steps": healthSummary.steps,
                "activeEnergyKilocalories": healthSummary.activeEnergyKilocalories,
                "updatedAt": Self.iso8601.string(from: healthSummary.updatedAt),
            ]
            if let heartRate = healthSummary.latestHeartRateBPM {
                payload["latestHeartRateBPM"] = heartRate
            }
            return payload
        case .focusStatus:
            guard focusAuthorization == .authorized else {
                throw SystemDataError.permissionRequired(capability)
            }
            guard let isFocused else { throw SystemDataError.dataUnavailable(capability) }
            return [
                "isFocused": isFocused,
                "updatedAt": Self.iso8601.string(from: focusUpdatedAt ?? .now),
            ]
        case .camera, .microphone:
            throw SystemDataError.dataUnavailable(capability)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshLocationAuthorization()
        if locationAuthorization == .authorized {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last else { return }
        location = DeviceLocationData(
            latitude: value.coordinate.latitude,
            longitude: value.coordinate.longitude,
            horizontalAccuracy: value.horizontalAccuracy,
            timestamp: value.timestamp
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        if (error as? CLError)?.code != .locationUnknown {
            lastErrorMessage = error.localizedDescription
        }
    }

    @objc private func applicationDidBecomeActive() {
        Task { await refreshAll() }
    }

    private func refreshLocationAuthorization() {
        locationAuthorization = switch locationManager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        @unknown default: .unavailable
        }
    }

    private func cumulativeQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return 0 }
        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        let statistics = try await descriptor.result(for: healthStore)
        return statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0
    }

    private func latestQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.date(byAdding: .day, value: -7, to: .now),
            end: .now
        )
        let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.endDate, order: .reverse)],
            limit: 1
        )
        return try await descriptor.result(for: healthStore).first?.quantity.doubleValue(for: unit)
    }

    private static func focusAuthorization(
        from status: INFocusStatusAuthorizationStatus
    ) -> SystemDataAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unavailable
        }
    }

    private static let healthReadTypes: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .stepCount),
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
        HKObjectType.quantityType(forIdentifier: .heartRate),
    ].compactMap { $0 }.reduce(into: Set<HKObjectType>()) { $0.insert($1) }

    private static let iso8601 = ISO8601DateFormatter()
}
