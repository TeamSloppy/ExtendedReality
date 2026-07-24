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
final class MapsSession: InputTarget {
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
    @ObservationIgnored private var visibleRegion: MKCoordinateRegion?

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
        setCameraRegion(
            MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 8_000,
                longitudinalMeters: 16_000
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
            setCameraRegion(Self.navigationRegion(for: route.polyline.boundingMapRect))
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

    func updateVisibleRegion(_ region: MKCoordinateRegion) {
        guard Self.isValid(region) else { return }
        visibleRegion = region
    }

    func handle(_ command: InputCommand) {
        switch command {
        case .scroll(let delta):
            pan(by: delta)
        case .magnify(let scaleDelta, _):
            zoom(by: scaleDelta)
        default:
            break
        }
    }

    private func pan(by delta: CGVector) {
        guard delta.dx.isFinite, delta.dy.isFinite,
              var region = visibleRegion else { return }
        region.center.latitude -= Double(delta.dy) * region.span.latitudeDelta * 0.8
        region.center.longitude += Double(delta.dx) * region.span.longitudeDelta * 0.8
        setCameraRegion(Self.normalized(region))
    }

    private func zoom(by scaleDelta: CGFloat) {
        guard scaleDelta.isFinite, scaleDelta > 0,
              var region = visibleRegion else { return }
        let factor = 1 / Double(scaleDelta)
        region.span.latitudeDelta *= factor
        region.span.longitudeDelta *= factor
        setCameraRegion(Self.normalized(region))
    }

    private func setCameraRegion(_ region: MKCoordinateRegion) {
        let normalized = Self.normalized(region)
        visibleRegion = normalized
        cameraPosition = .region(normalized)
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

    nonisolated private static func navigationRegion(for rect: MKMapRect) -> MKCoordinateRegion {
        var region = MKCoordinateRegion(rect)
        region.span.latitudeDelta = max(region.span.latitudeDelta * 1.65, 0.018)
        region.span.longitudeDelta = max(region.span.longitudeDelta * 1.45, 0.04)
        return normalized(region)
    }

    nonisolated private static func normalized(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        var region = region
        region.center.latitude = min(max(region.center.latitude, -85), 85)
        region.center.longitude = ((region.center.longitude + 180).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180
        region.span.latitudeDelta = min(max(region.span.latitudeDelta, 0.002), 120)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta, 0.004), 180)
        return region
    }

    nonisolated private static func isValid(_ region: MKCoordinateRegion) -> Bool {
        region.center.latitude.isFinite
            && region.center.longitude.isFinite
            && region.span.latitudeDelta.isFinite
            && region.span.longitudeDelta.isFinite
            && region.span.latitudeDelta > 0
            && region.span.longitudeDelta > 0
    }

    nonisolated fileprivate static var cameraBounds: MapCameraBounds {
        MapCameraBounds(
            minimumDistance: 250,
            maximumDistance: 8_000_000
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
        GeometryReader { proxy in
            let lensSize = NavigationLensLayout.size(in: proxy.size)

            navigationLens
                .frame(width: lensSize.width, height: lensSize.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Maps route to \(session.destinationTitle)")
    }

    private var navigationLens: some View {
        ZStack {
            Map(
                position: $session.cameraPosition,
                bounds: MapsSession.cameraBounds,
                interactionModes: [.pan, .zoom]
            ) {
                if let route = session.route {
                    MapPolyline(route.polyline)
                        .stroke(
                            .cyan.opacity(0.94),
                            style: StrokeStyle(
                                lineWidth: 9,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
                if !session.usesCurrentLocation, let source = session.sourceItem {
                    Annotation("Start", coordinate: source.placemark.coordinate) {
                        NavigationPositionMarker()
                    }
                }
                if let destination = session.destinationItem {
                    Marker(session.destinationTitle, coordinate: destination.placemark.coordinate)
                        .tint(.red.opacity(0.82))
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
            .onMapCameraChange(frequency: .onEnd) { context in
                session.updateVisibleRegion(context.region)
            }
            .saturation(0.78)
            .contrast(1.08)

            NavigationLensVignette()

            if session.usesCurrentLocation, session.route != nil {
                NavigationPositionMarker()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 30)
                    .allowsHitTesting(false)
            }

            lensContent
                .allowsHitTesting(false)
        }
        .clipShape(Ellipse())
        .overlay {
            Ellipse()
                .strokeBorder(.cyan.opacity(0.16), lineWidth: 1.5)
        }
        .shadow(color: .cyan.opacity(0.13), radius: 30)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    @ViewBuilder
    private var lensContent: some View {
        if session.isLoading {
            ProgressView()
                .controlSize(.large)
                .tint(.white.opacity(0.88))
        } else if session.route != nil {
            VStack(spacing: 0) {
                if let instruction = session.firstInstruction {
                    NavigationTurnCallout(instruction: instruction)
                        .padding(.top, 22)
                }

                Spacer(minLength: 0)

                if let summary = session.routeSummary {
                    Label(summary, systemImage: session.transport.systemImage)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.48), in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 22)
                        .padding(.bottom, 18)
                }
            }
        } else {
            Label("Choose a route", systemImage: "location.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(.black.opacity(0.44), in: Capsule())
        }
    }
}

private enum NavigationLensLayout {
    static func size(in availableSize: CGSize) -> CGSize {
        let width = min(availableSize.width * 0.92, availableSize.height * 2.45)
        let height = min(availableSize.height * 0.82, width * 0.46)
        return CGSize(width: max(width, 1), height: max(height, 1))
    }
}

private struct NavigationPositionMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.indigo.opacity(0.96), .indigo.opacity(0.7)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 34
                    )
                )
                .frame(width: 66, height: 66)
                .blur(radius: 3)

            Image(systemName: "location.north.fill")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .indigo.opacity(0.72), radius: 8)
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }
}

private struct NavigationTurnCallout: View {
    let instruction: String

    var body: some View {
        Label(instruction, systemImage: turnSystemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1)
            }
            .frame(maxWidth: 330)
            .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
    }

    private var turnSystemImage: String {
        let normalized = instruction.lowercased()
        if normalized.contains("left") { return "arrow.turn.up.left" }
        if normalized.contains("right") { return "arrow.turn.up.right" }
        if normalized.contains("arrive") || normalized.contains("destination") {
            return "flag.checkered"
        }
        return "arrow.up"
    }
}

private struct NavigationLensVignette: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.42), .clear, .black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.black.opacity(0.48), .clear, .black.opacity(0.48)],
                startPoint: .leading,
                endPoint: .trailing
            )
            Color.indigo.opacity(0.08)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
