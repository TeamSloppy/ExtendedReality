import MapKit
import Observation
import SwiftUI

enum MapsTransportMode: String, CaseIterable, Identifiable, Sendable {
    case walking
    case cycling
    case driving
    case transit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: "Walk"
        case .cycling: "Bike"
        case .driving: "Drive"
        case .transit: "Transit"
        }
    }

    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .driving: "car.fill"
        case .transit: "tram.fill"
        }
    }

    var directionsTransportType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .cycling: .cycling
        case .driving: .automobile
        case .transit: .transit
        }
    }

    var launchOption: String {
        switch self {
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .cycling: MKLaunchOptionsDirectionsModeCycling
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .transit: MKLaunchOptionsDirectionsModeTransit
        }
    }

    init(mapsURLValue: String?) {
        switch mapsURLValue?.lowercased() {
        case "driving", "d": self = .driving
        case "cycling", "b": self = .cycling
        case "transit", "r": self = .transit
        default: self = .walking
        }
    }
}

struct AppleMapsRouteLink: Equatable, Sendable {
    let source: String?
    let destination: String
    let transport: MapsTransportMode

    static func parse(_ url: URL) -> Self? {
        guard let host = url.host?.lowercased(),
              host == "maps.apple.com" || host.hasSuffix(".maps.apple.com") else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        func firstValue(_ names: [String]) -> String? {
            for name in names {
                if let value = items.first(where: { $0.name.lowercased() == name })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        let source = firstValue(["source", "saddr"])
        let destination = firstValue(["destination", "daddr"])
            ?? firstValue(["address", "q", "name"])
            ?? firstValue(["coordinate", "ll"])
        guard let destination else { return nil }
        let mode = firstValue(["mode", "dirflg"])
        return Self(
            source: source,
            destination: destination,
            transport: MapsTransportMode(mapsURLValue: mode)
        )
    }
}

enum MapsSessionError: LocalizedError {
    case locationUnavailable
    case destinationMissing
    case placeNotFound(String)
    case routeUnavailable
    case invalidAppleMapsLink

    var errorDescription: String? {
        switch self {
        case .locationUnavailable:
            "Allow location access in Settings or enter a starting point."
        case .destinationMissing:
            "Enter a destination."
        case .placeNotFound(let query):
            "Could not find “\(query)”."
        case .routeUnavailable:
            "Apple Maps could not build this route."
        case .invalidAppleMapsLink:
            "This Apple Maps link does not contain a destination."
        }
    }
}

@MainActor
@Observable
final class MapsSession {
    var sourceQuery = ""
    var destinationQuery = ""
    var usesCurrentLocation = true
    var transport: MapsTransportMode = .walking
    var cameraPosition: MapCameraPosition = .automatic
    private(set) var route: MKRoute?
    private(set) var sourceItem: MKMapItem?
    private(set) var destinationItem: MKMapItem?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let systemData: SystemDataStore

    init(systemData: SystemDataStore) {
        self.systemData = systemData
        centerOnCurrentLocation()
    }

    var destinationTitle: String {
        destinationItem?.name ?? destinationQuery.nonempty ?? "Choose a destination"
    }

    var routeSummary: String? {
        guard let route else { return nil }
        return "\(Self.durationFormatter.string(from: route.expectedTravelTime) ?? "—") · \(Self.distanceFormatter.string(fromDistance: route.distance))"
    }

    var firstInstruction: String? {
        route?.steps.first(where: { !$0.instructions.isEmpty })?.instructions
    }

    var shareURL: URL? {
        guard let destinationItem else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/directions"
        var queryItems: [URLQueryItem] = []
        if !usesCurrentLocation, let sourceItem {
            queryItems.append(URLQueryItem(name: "source", value: Self.routeValue(for: sourceItem)))
        }
        queryItems.append(URLQueryItem(name: "destination", value: Self.routeValue(for: destinationItem)))
        queryItems.append(URLQueryItem(name: "mode", value: transport.rawValue))
        components.queryItems = queryItems
        return components.url
    }

    func centerOnCurrentLocation() {
        guard let location = systemData.location else { return }
        cameraPosition = .region(
            MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 1_800,
                longitudinalMeters: 1_800
            )
        )
    }

    func planRoute() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let destinationText = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destinationText.isEmpty else { throw MapsSessionError.destinationMissing }
            let destination = try await resolve(destinationText)
            let source: MKMapItem
            if usesCurrentLocation {
                guard let location = systemData.location else {
                    systemData.requestLocationAccess()
                    throw MapsSessionError.locationUnavailable
                }
                source = Self.mapItem(for: location.coordinate, name: "Current Location")
            } else {
                let sourceText = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sourceText.isEmpty else { throw MapsSessionError.locationUnavailable }
                source = try await resolve(sourceText)
            }

            let request = MKDirections.Request()
            request.source = source
            request.destination = destination
            request.transportType = transport.directionsTransportType
            request.requestsAlternateRoutes = false
            guard let route = try await MKDirections(request: request).calculate().routes.first else {
                throw MapsSessionError.routeUnavailable
            }

            sourceItem = source
            destinationItem = destination
            self.route = route
            cameraPosition = .rect(Self.padded(route.polyline.boundingMapRect))
        } catch {
            route = nil
            destinationItem = nil
            errorMessage = error.localizedDescription
        }
    }

    func importAppleMapsLink(_ rawValue: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let suppliedURL = Self.firstURL(in: rawValue) else {
                throw MapsSessionError.invalidAppleMapsLink
            }
            let expandedURL = try await Self.expandIfNeeded(suppliedURL)
            guard let imported = AppleMapsRouteLink.parse(expandedURL) else {
                throw MapsSessionError.invalidAppleMapsLink
            }
            let usesImportedCurrentLocation = imported.source.map(Self.isCurrentLocationLabel) ?? true
            sourceQuery = usesImportedCurrentLocation ? "" : imported.source ?? ""
            usesCurrentLocation = usesImportedCurrentLocation
            destinationQuery = imported.destination
            transport = imported.transport
            isLoading = false
            await planRoute()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openInAppleMaps() {
        guard let destinationItem else { return }
        let items = usesCurrentLocation || sourceItem == nil
            ? [destinationItem]
            : [sourceItem, destinationItem].compactMap { $0 }
        MKMapItem.openMaps(
            with: items,
            launchOptions: [MKLaunchOptionsDirectionsModeKey: transport.launchOption]
        )
    }

    private func resolve(_ query: String) async throws -> MKMapItem {
        if let coordinate = Self.coordinate(from: query) {
            return Self.mapItem(for: coordinate, name: query)
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let currentLocation = systemData.location {
            request.region = MKCoordinateRegion(
                center: currentLocation.coordinate,
                latitudinalMeters: 80_000,
                longitudinalMeters: 80_000
            )
        }
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
            throw MapsSessionError.placeNotFound(query)
        }
        return item
    }

    nonisolated private static func firstURL(in rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return trimmed
            .split(whereSeparator: \Character.isWhitespace)
            .compactMap { URL(string: String($0)) }
            .first(where: { $0.scheme != nil })
    }

    nonisolated private static func expandIfNeeded(_ url: URL) async throws -> URL {
        guard url.host?.lowercased().hasSuffix("maps.apple") == true else { return url }
        let (_, response) = try await URLSession.shared.data(from: url)
        return response.url ?? url
    }

    nonisolated private static func coordinate(from value: String) -> CLLocationCoordinate2D? {
        let pieces = value.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard pieces.count == 2,
              let latitude = CLLocationDegrees(pieces[0]),
              let longitude = CLLocationDegrees(pieces[1]),
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    nonisolated private static func isCurrentLocationLabel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "current location" || normalized == "my location"
    }

    nonisolated private static func mapItem(
        for coordinate: CLLocationCoordinate2D,
        name: String
    ) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    nonisolated private static func padded(_ rect: MKMapRect) -> MKMapRect {
        rect.insetBy(
            dx: -max(rect.size.width * 0.16, 1_200),
            dy: -max(rect.size.height * 0.22, 1_200)
        )
    }

    nonisolated private static func routeValue(for item: MKMapItem) -> String {
        if let name = item.name, !name.isEmpty, name != "Current Location" { return name }
        return "\(item.placemark.coordinate.latitude),\(item.placemark.coordinate.longitude)"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let distanceFormatter: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter
    }()
}

struct MapsSurfaceView: View {
    @Bindable var session: MapsSession

    var body: some View {
        Map(position: $session.cameraPosition, interactionModes: []) {
            if let route = session.route {
                MapPolyline(route.polyline)
                    .stroke(.cyan.opacity(0.88), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
            if let source = session.sourceItem {
                Annotation("Start", coordinate: source.placemark.coordinate) {
                    Circle()
                        .fill(.cyan)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 5)
                }
            }
            if let destination = session.destinationItem {
                Marker(session.destinationTitle, coordinate: destination.placemark.coordinate)
                    .tint(.red)
            }
        }
        .mapStyle(
            .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        )
        .overlay {
            LinearGradient(
                colors: [.black.opacity(0.34), .clear, .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            destinationHeader
        }
        .overlay(alignment: .bottomLeading) {
            routeGuidance
        }
        .background(Color(red: 0.04, green: 0.055, blue: 0.065))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Maps route to \(session.destinationTitle)")
    }

    private var destinationHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "map.fill")
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("APPLE MAPS")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.white.opacity(0.62))
                Text(session.destinationTitle)
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(18)
    }

    @ViewBuilder
    private var routeGuidance: some View {
        if session.isLoading {
            Label("Building route…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(18)
        } else if let summary = session.routeSummary {
            HStack(spacing: 14) {
                Image(systemName: session.transport.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 36, height: 36)
                    .background(.cyan.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary)
                        .font(.headline.monospacedDigit())
                    if let instruction = session.firstInstruction {
                        Text(instruction)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(18)
        } else {
            Label("Choose a route on iPhone", systemImage: "location.magnifyingglass")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(18)
        }
    }
}

private extension DeviceLocationData {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
