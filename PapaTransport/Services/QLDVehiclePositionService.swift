import CoreLocation
import Foundation
import MapKit

/// A vehicle currently reporting its position.
///
/// `nonisolated` because it crosses isolation domains: built inside services,
/// passed through task groups, consumed by main-actor views. The target
/// defaults to main-actor isolation, which would otherwise make that illegal.
nonisolated struct LiveVehicle: Identifiable, Equatable, Sendable {
    let id: String
    /// The trip/run this vehicle is working, used to match it back to a
    /// departure on the board so the pin can open that trip's detail.
    let tripId: String
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

    /// Two consumers now want this feed on roughly the same cadence — the map
    /// (pins) and the departure board ("N stops away"). The cache means they
    /// share one request instead of each fetching 230 KB every refresh.
    private let cache = FeedCache()

    private actor FeedCache {
        private var feeds: [Bool: (feed: GTFSRTFeedMessage, fetchedAt: Date)] = [:]
        private var inFlight: [Bool: Task<GTFSRTFeedMessage?, Never>] = [:]

        /// Comfortably shorter than the 60 s board refresh, so a manual pull
        /// still gets fresh positions.
        private static let maxAge: TimeInterval = 20

        func feed(rail: Bool, fetch: @escaping @Sendable () async -> GTFSRTFeedMessage?) async -> GTFSRTFeedMessage? {
            if let cached = feeds[rail], Date().timeIntervalSince(cached.fetchedAt) < Self.maxAge {
                return cached.feed
            }
            // Coalesce concurrent callers onto one request.
            if let existing = inFlight[rail] { return await existing.value }

            let task = Task { await fetch() }
            inFlight[rail] = task
            let result = await task.value
            inFlight[rail] = nil
            if let result { feeds[rail] = (result, Date()) }
            return result
        }
    }

    /// `currentStopSequence` keyed by trip id, for the departure board.
    ///
    /// Vehicles that have not reported a sequence are omitted rather than
    /// reported as sequence 0, which would read as "at the first stop".
    func stopSequencesByTrip(rail: Bool) async -> [String: Int] {
        guard let feed = await cachedFeed(rail: rail) else { return [:] }
        var result: [String: Int] = [:]
        for vehicle in feed.entities.compactMap(\.vehicle)
        where !vehicle.tripId.isEmpty && vehicle.currentStopSequence > 0 {
            result[vehicle.tripId] = Int(vehicle.currentStopSequence)
        }
        return result
    }

    /// Vehicles inside `region`, capped so a zoomed-out map cannot drop
    /// thousands of annotations onto MapKit at once.
    func vehicles(
        rail: Bool,
        in region: MKCoordinateRegion,
        limit: Int = 250
    ) async -> [LiveVehicle] {
        guard let feed = await cachedFeed(rail: rail) else { return [] }

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
                tripId: vehicle.tripId,
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

    private func cachedFeed(rail: Bool) async -> GTFSRTFeedMessage? {
        await cache.feed(rail: rail) { [self] in await fetchFeed(rail: rail) }
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
