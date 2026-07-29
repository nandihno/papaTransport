import CoreLocation
import Foundation
import MapKit

/// A vehicle currently reporting its position on the TransLink realtime feed.
struct LiveVehicle: Identifiable, Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
    /// Degrees clockwise from true north. Nil when the operator omits it —
    /// the map shows a plain dot rather than guessing a heading.
    let bearing: Double?
    let routeLabel: String
    let isRail: Bool
    let isStopped: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Live vehicle positions for South East Queensland.
///
/// TransLink publishes VehiclePositions alongside TripUpdates on the same
/// unauthenticated GTFS-realtime API. The mode-split endpoints are used
/// because the rail payload is ~12 KB against ~230 KB for the whole network.
/// `nonisolated` so the protobuf decode — up to ~1,100 vehicles every 60 s —
/// stays off the main thread. The target defaults to main-actor isolation.
nonisolated final class QLDVehiclePositionService {
    static let shared = QLDVehiclePositionService()

    private init() {}

    private let busURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/VehiclePositions/Bus")!
    private let railURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/VehiclePositions/Rail")!

    /// Vehicles inside `region`, capped so a zoomed-out map cannot drop
    /// thousands of annotations onto MapKit at once.
    func vehicles(
        rail: Bool,
        in region: MKCoordinateRegion,
        limit: Int = 250
    ) async -> [LiveVehicle] {
        guard let feed = await fetchFeed(rail: rail) else { return [] }

        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        let visible = feed.entities.compactMap(\.vehicle).filter { vehicle in
            vehicle.hasValidPosition
                && vehicle.latitude >= minLat && vehicle.latitude <= maxLat
                && vehicle.longitude >= minLon && vehicle.longitude <= maxLon
        }

        guard !visible.isEmpty else { return [] }

        let routeNames = await routeShortNames(for: visible.map(\.routeId))

        return visible.prefix(limit).map { vehicle in
            LiveVehicle(
                id: vehicle.vehicleId.isEmpty ? vehicle.tripId : vehicle.vehicleId,
                latitude: vehicle.latitude,
                longitude: vehicle.longitude,
                bearing: vehicle.bearing,
                routeLabel: routeNames[vehicle.routeId]
                    ?? vehicle.vehicleLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                isRail: rail,
                isStopped: vehicle.currentStatus == .stoppedAt
            )
        }
    }

    private func fetchFeed(rail: Bool) async -> GTFSRTFeedMessage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: rail ? railURL : busURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return try GTFSRTFeedMessage(data: data)
        } catch {
            return nil
        }
    }

    private func routeShortNames(for routeIds: [String]) async -> [String: String] {
        let unique = Array(Set(routeIds.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        do {
            try await GTFSDatabase.shared.ensureReady()
            return try await GTFSDatabase.shared.routeShortNames(for: unique)
        } catch {
            return [:]
        }
    }
}
