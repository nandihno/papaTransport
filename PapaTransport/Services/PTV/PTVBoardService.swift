//
//  PTVBoardService.swift
//  PapaTransport
//
//  Builds the stop/station departure board from the PTV Timetable API,
//  mapping onto the same `BusInfo` models the GTFS-backed services produce so
//  the UI is unchanged.
//
//  One instance per mode: PTV differs only by route_type between Victorian
//  train and Victorian bus.
//
//  Unlike the GTFS path — one batched SQL query for every stop at once — PTV
//  requires a request per stop. The nearby-stop count is therefore capped and
//  the client throttles and caches; see PTVAPIClient.
//

import Foundation
import CoreLocation

final class PTVBoardService: TrainBoardProviding {

    /// Station boards show only the next 2 hours. The board groups by line and
    /// collapses each group, so a whole station's worth of departures costs a
    /// row per line rather than a row per train — hence the generous caps.
    static let victorianTrain = PTVBoardService(
        routeType: .train,
        provider: .victorianTrainPTV,
        nearbyRadiusMeters: 5_000,
        fallbackRadiusMeters: 5_000,
        maxStops: 8,
        departureWindowSeconds: 2 * 60 * 60,
        departuresPerRequest: 10,
        departuresPerLine: 10,
        maxDeparturesPerStop: 120
    )

    /// Bus stops apply no time window — just the next departures — otherwise a
    /// late-night board would hide tomorrow's first service.
    ///
    /// The bus board lists departures flat rather than grouped, so the caps are
    /// tighter than the train's: enough that every route serving the stop is
    /// represented, not so many that the list becomes a wall of times.
    static let victorianBus = PTVBoardService(
        routeType: .bus,
        provider: .victorianPTV,
        nearbyRadiusMeters: 300,
        fallbackRadiusMeters: 800,
        maxStops: 10,
        departureWindowSeconds: nil,
        departuresPerRequest: 6,
        departuresPerLine: 3,
        maxDeparturesPerStop: 15
    )

    /// Tram stops sit closer together than bus stops, so a tighter default
    /// radius still finds plenty without wasting per-stop requests.
    static let victorianTram = PTVBoardService(
        routeType: .tram,
        provider: .victorianTramPTV,
        nearbyRadiusMeters: 250,
        fallbackRadiusMeters: 600,
        maxStops: 10,
        departureWindowSeconds: nil,
        departuresPerRequest: 6,
        departuresPerLine: 3,
        maxDeparturesPerStop: 15
    )

    static let departureWindowSeconds = 2 * 60 * 60
    static let departureWindowDescription = "next 2 hours"

    let provider: BusProvider

    private let routeType: PTVRouteType
    private let nearbyRadiusMeters: Int
    /// PTV stop coordinates are sparser than the GTFS table, so a radius that
    /// works against SQLite can return nothing here. Widen once rather than
    /// showing an empty board.
    private let fallbackRadiusMeters: Int
    private let maxStops: Int
    private let departureWindow: Int?
    private let melbourneTimeZone = TimeZone(identifier: "Australia/Melbourne")!

    /// PTV applies `max_results` **per route and direction**, not per stop, so
    /// a request for 10 comes back with 10 for every line serving the station —
    /// 240 at Flinders Street. Measured, not documented.
    private let departuresPerRequest: Int
    private let departuresPerLine: Int
    private let maxDeparturesPerStop: Int

    private init(
        routeType: PTVRouteType,
        provider: BusProvider,
        nearbyRadiusMeters: Int,
        fallbackRadiusMeters: Int,
        maxStops: Int,
        departureWindowSeconds: Int?,
        departuresPerRequest: Int,
        departuresPerLine: Int,
        maxDeparturesPerStop: Int
    ) {
        self.routeType = routeType
        self.provider = provider
        self.nearbyRadiusMeters = nearbyRadiusMeters
        self.fallbackRadiusMeters = fallbackRadiusMeters
        self.maxStops = maxStops
        self.departureWindow = departureWindowSeconds
        self.departuresPerRequest = departuresPerRequest
        self.departuresPerLine = departuresPerLine
        self.maxDeparturesPerStop = maxDeparturesPerStop
    }

    enum BoardError: LocalizedError {
        case tripPatternUnavailable

        var errorDescription: String? {
            switch self {
            case .tripPatternUnavailable:
                return "The stop pattern for this service is not available right now."
            }
        }
    }

    // MARK: - Board

    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo {
        let stops = try await nearbyStops(latitude: latitude, longitude: longitude, radius: nearbyRadiusMeters)
        return try await makeBoard(
            stops: stops,
            referenceLatitude: latitude,
            referenceLongitude: longitude,
            includeFavourites: true
        )
    }

    /// PTV has no bounding-box query, so the region is served as a
    /// centre-plus-radius search covering the box's furthest corner.
    func fetchBusInfo(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        referenceLatitude: Double,
        referenceLongitude: Double
    ) async throws -> BusInfo {
        let centreLat = (minLat + maxLat) / 2
        let centreLon = (minLon + maxLon) / 2
        let centre = CLLocation(latitude: centreLat, longitude: centreLon)
        let corner = CLLocation(latitude: maxLat, longitude: maxLon)
        let radius = min(Int(centre.distance(from: corner).rounded()), 20_000)

        let stops = try await nearbyStops(latitude: centreLat, longitude: centreLon, radius: max(radius, 300))
        return try await makeBoard(
            stops: stops,
            referenceLatitude: referenceLatitude,
            referenceLongitude: referenceLongitude,
            includeFavourites: false
        )
    }

    func fetchFavouriteBusInfo(referenceLatitude latitude: Double, longitude: Double) async throws -> BusInfo {
        let favourites = await MainActor.run { FavouriteBusStopStore.shared.favourites(for: provider) }
        guard !favourites.isEmpty else {
            return emptyBoard()
        }

        let idMap = await PTVStopIDResolver.shared.ptvStopIds(
            for: favourites,
            routeType: routeType,
            provider: provider
        )
        let boards = await departureBoards(forStopIds: Array(idMap.values))
        let userLocation = CLLocation(latitude: latitude, longitude: longitude)

        let favouriteStops: [NearbyBusStop] = favourites.compactMap { favourite in
            guard let stopId = idMap[favourite.stopId],
                  let departures = boards.departures[stopId], !departures.isEmpty
            else { return nil }

            let distance = Int(userLocation.distance(
                from: CLLocation(latitude: favourite.latitude, longitude: favourite.longitude)
            ))

            return NearbyBusStop(
                id: favourite.stopId,
                stopName: favourite.stopName,
                stopCode: favourite.stopCode,
                latitude: favourite.latitude,
                longitude: favourite.longitude,
                distanceMeters: distance,
                departures: departures
            )
        }

        return BusInfo(
            provider: provider,
            nearbyStops: [],
            favouriteStops: favouriteStops,
            alerts: alerts(from: boards.disruptions),
            localTimeAtFetch: currentMelbourneTimeString(),
            locationAvailable: true
        )
    }

    // MARK: - Trip detail

    func fetchTripDetail(for departure: BusDeparture, stopId: String) async throws -> BusTripDetail {
        let response: PTVDeparturesResponse
        do {
            response = try await PTVAPIClient.shared.get(
                PTVEndpoint.pattern(runRef: departure.tripId, routeType: routeType),
                as: PTVDeparturesResponse.self,
                cacheFor: 20
            )
        } catch let error as PTVAPIClient.PTVError {
            // PTV rejects some run references it hands out itself — notably bus
            // runs that roll past midnight into the next service day. Treat that
            // as an unavailable pattern rather than surfacing a raw HTTP error.
            if case .http(let status, _) = error, status == 404 {
                throw BoardError.tripPatternUnavailable
            }
            throw error
        }

        let pattern = response.departures
        guard !pattern.isEmpty else { throw BoardError.tripPatternUnavailable }

        // Nearby stops carry a PTV id, but favourites keep their original GTFS
        // id so they stay removable, so fall back to the resolved mapping.
        var targetStopId = Int(stopId)
        if targetStopId == nil || !pattern.contains(where: { $0.stopId == targetStopId }) {
            targetStopId = await PTVStopIDResolver.shared
                .cachedPTVStopId(forOriginalId: stopId, provider: provider) ?? targetStopId
        }

        guard let selectedIndex =
            pattern.firstIndex(where: { $0.stopId == targetStopId })
            ?? pattern.firstIndex(where: { $0.departureSequence == departure.stopSequence })
        else {
            throw BoardError.tripPatternUnavailable
        }

        func detail(_ entry: PTVDeparture, isSelected: Bool) -> BusTripStopDetail {
            let stop = response.stops[String(entry.stopId)]
            return BusTripStopDetail(
                stopId: String(entry.stopId),
                stopName: stop?.stopName ?? "Stop \(entry.stopId)",
                stopCode: nil,
                latitude: stop?.latitude ?? 0,
                longitude: stop?.longitude ?? 0,
                scheduledTime: entry.scheduledDeparture.map(timeString),
                predictedTime: entry.estimatedDeparture.map(timeString),
                delaySeconds: entry.delaySeconds,
                status: status(for: entry),
                stopSequence: entry.departureSequence,
                isSelectedStop: isSelected
            )
        }

        let leading = pattern[..<selectedIndex].map { detail($0, isSelected: false) }
        let trailing = pattern[selectedIndex...].enumerated().map { offset, entry in
            detail(entry, isSelected: offset == 0)
        }

        guard let terminal = trailing.last else { throw BoardError.tripPatternUnavailable }
        let selected = pattern[selectedIndex]

        return BusTripDetail(
            tripId: departure.tripId,
            routeShortName: departure.routeShortName,
            routeLongName: departure.routeLongName,
            headsign: departure.headsign,
            selectedStopName: response.stops[String(selected.stopId)]?.stopName ?? "",
            selectedStopSequence: selected.departureSequence,
            earlierStopCount: selectedIndex,
            remainingStopCount: max(0, trailing.count - 1),
            terminalStopName: terminal.stopName,
            terminalScheduledTime: terminal.scheduledTime,
            terminalPredictedTime: terminal.predictedTime,
            stopsBeforeSelected: leading,
            stopsFromSelected: trailing
        )
    }

    // MARK: - Stop discovery (favourites picker)

    /// `/v3/stops/location` returns at most this many stops however large the
    /// radius — measured, not documented. A wide region therefore has to be
    /// covered by several smaller queries.
    private static let stopsPerRequestCap = 30

    /// Radius beyond which a single query starts hitting `stopsPerRequestCap`
    /// in dense areas, so the region gets subdivided instead.
    private static let subdivideAboveMeters = 1_200

    /// Stops inside a map region, for the favourites picker.
    ///
    /// No departures are fetched here, so this is far cheaper per stop than a
    /// board refresh. A tight region costs one request; a wide one is split
    /// into quadrants to work around the server-side result cap.
    func stopsInRegion(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        limit: Int = 200
    ) async throws -> [PTVStop] {
        let centre = CLLocation(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let corner = CLLocation(latitude: maxLat, longitude: maxLon)
        let radius = Int(centre.distance(from: corner).rounded())

        let cells: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)]
        if radius > Self.subdivideAboveMeters {
            let midLat = (minLat + maxLat) / 2
            let midLon = (minLon + maxLon) / 2
            cells = [
                (minLat, midLat, minLon, midLon),
                (minLat, midLat, midLon, maxLon),
                (midLat, maxLat, minLon, midLon),
                (midLat, maxLat, midLon, maxLon),
            ]
        } else {
            cells = [(minLat, maxLat, minLon, maxLon)]
        }

        let collected = await withTaskGroup(of: [PTVStop].self) { group in
            for cell in cells {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return await self.stops(in: cell)
                }
            }
            var all: [PTVStop] = []
            for await stops in group { all.append(contentsOf: stops) }
            return all
        }

        // Quadrants overlap at the seams, and PTV searches a radius rather than
        // a box, so deduplicate and trim to what the map is actually showing.
        var seen: Set<Int> = []
        return collected
            .filter { $0.latitude >= minLat && $0.latitude <= maxLat
                   && $0.longitude >= minLon && $0.longitude <= maxLon }
            .filter { seen.insert($0.stopId).inserted }
            .sorted { ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude) }
            .prefix(limit)
            .map { $0 }
    }

    private func stops(
        in cell: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    ) async -> [PTVStop] {
        let centreLat = (cell.minLat + cell.maxLat) / 2
        let centreLon = (cell.minLon + cell.maxLon) / 2
        let centre = CLLocation(latitude: centreLat, longitude: centreLon)
        let corner = CLLocation(latitude: cell.maxLat, longitude: cell.maxLon)
        let radius = min(max(Int(centre.distance(from: corner).rounded()), 300), 30_000)

        do {
            return try await PTVAPIClient.shared.get(
                PTVEndpoint.stopsNear(
                    latitude: centreLat,
                    longitude: centreLon,
                    routeTypes: [routeType],
                    maxDistanceMeters: radius
                ),
                as: PTVStopsResponse.self,
                cacheFor: 120
            ).stops
        } catch {
            print("⚠️ PTV stop search failed for region cell: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Fetching

    private func nearbyStops(latitude: Double, longitude: Double, radius: Int) async throws -> [PTVStop] {
        func request(_ metres: Int) async throws -> [PTVStop] {
            try await PTVAPIClient.shared.get(
                PTVEndpoint.stopsNear(
                    latitude: latitude,
                    longitude: longitude,
                    routeTypes: [routeType],
                    maxDistanceMeters: metres
                ),
                as: PTVStopsResponse.self,
                cacheFor: 120
            ).stops
        }

        var found = try await request(radius)
        if found.isEmpty, fallbackRadiusMeters > radius {
            found = try await request(fallbackRadiusMeters)
        }

        return found
            .sorted { ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude) }
            .prefix(maxStops)
            .map { $0 }
    }

    private struct StopBoards {
        var departures: [Int: [BusDeparture]] = [:]
        var disruptions: [PTVDisruption] = []
    }

    /// Fetches boards for several stops at once. `PTVAPIClient` caps how many
    /// of these actually run in parallel.
    private func departureBoards(forStopIds stopIds: [Int]) async -> StopBoards {
        guard !stopIds.isEmpty else { return StopBoards() }

        return await withTaskGroup(of: (Int, [BusDeparture], [PTVDisruption]).self) { group in
            for stopId in Set(stopIds) {
                group.addTask { [weak self] in
                    guard let self else { return (stopId, [], []) }
                    let board = await self.departures(forStopId: stopId)
                    return (stopId, board.departures, board.disruptions)
                }
            }
            var result = StopBoards()
            for await (stopId, departures, disruptions) in group {
                if !departures.isEmpty { result.departures[stopId] = departures }
                result.disruptions.append(contentsOf: disruptions)
            }
            return result
        }
    }

    private func departures(
        forStopId stopId: Int
    ) async -> (departures: [BusDeparture], disruptions: [PTVDisruption]) {
        do {
            let response = try await PTVAPIClient.shared.get(
                PTVEndpoint.departures(
                    routeType: routeType,
                    stopId: stopId,
                    maxResults: departuresPerRequest
                ),
                as: PTVDeparturesResponse.self
            )
            return (busDepartures(from: response), Array(response.disruptions.values))
        } catch {
            print("⚠️ PTV departures failed for stop \(stopId): \(error.localizedDescription)")
            return ([], [])
        }
    }

    // MARK: - Mapping

    private struct UpcomingDeparture {
        let entry: PTVDeparture
        let when: Date

        /// Boards are grouped and read per line and per direction, so this is
        /// the unit that has to stay represented.
        var lineKey: String { "\(entry.routeId)|\(entry.directionId)" }
    }

    /// PTV merges every route and direction serving a stop into one list. Simply
    /// keeping the earliest N therefore starves the quieter lines: at Flinders
    /// Street the next six departures cover five of the twelve lines, and
    /// Belgrave can vanish from Richmond entirely.
    ///
    /// Take turns across the line groups instead — one departure from each, then
    /// a second from each — so the overall cap is spent on breadth first, then
    /// restore time order for display.
    private func selectDepartures(from upcoming: [UpcomingDeparture]) -> [UpcomingDeparture] {
        var groups: [[UpcomingDeparture]] = []
        var indexForLine: [String: Int] = [:]

        for departure in upcoming {
            if let index = indexForLine[departure.lineKey] {
                groups[index].append(departure)
            } else {
                indexForLine[departure.lineKey] = groups.count
                groups.append([departure])
            }
        }

        var selected: [UpcomingDeparture] = []
        rounds: for round in 0..<departuresPerLine {
            for group in groups where group.count > round {
                selected.append(group[round])
                if selected.count >= maxDeparturesPerStop { break rounds }
            }
        }

        return selected.sorted { $0.when < $1.when }
    }

    private func busDepartures(from response: PTVDeparturesResponse) -> [BusDeparture] {
        let now = Date()
        let cutoff = departureWindow.map { now.addingTimeInterval(TimeInterval($0)) }

        let upcoming = response.departures
            .compactMap { entry -> UpcomingDeparture? in
                guard let when = entry.effectiveDeparture, when >= now else { return nil }
                if let cutoff, when > cutoff { return nil }
                return UpcomingDeparture(entry: entry, when: when)
            }
            .sorted { $0.when < $1.when }

        return selectDepartures(from: upcoming)
            .map { departure in
                let entry = departure.entry
                let when = departure.when
                let route = response.routes[String(entry.routeId)]
                let run = response.runs[String(entry.runRef)]
                let direction = response.directions[String(entry.directionId)]

                let routeName = route?.routeName ?? ""
                let routeNumber = route?.routeNumber ?? ""
                let scheduled = entry.scheduledDeparture ?? when

                return BusDeparture(
                    tripId: entry.runRef,
                    routeShortName: routeNumber.isEmpty ? routeName : routeNumber,
                    routeLongName: routeName,
                    headsign: run?.destinationName.isEmpty == false
                        ? run?.destinationName
                        : direction?.directionName,
                    scheduledTime: timeString(scheduled),
                    scheduledSeconds: secondsSinceMelbourneMidnight(scheduled),
                    predictedTime: entry.estimatedDeparture.map(timeString),
                    delaySeconds: entry.delaySeconds ?? 0,
                    minutesAway: max(0, Int(when.timeIntervalSince(now) / 60)),
                    status: status(for: entry),
                    stopSequence: entry.departureSequence
                )
            }
    }

    private func makeBoard(
        stops: [PTVStop],
        referenceLatitude: Double,
        referenceLongitude: Double,
        includeFavourites: Bool
    ) async throws -> BusInfo {
        let favourites = includeFavourites
            ? await MainActor.run { FavouriteBusStopStore.shared.favourites(for: provider) }
            : []

        let idMap = favourites.isEmpty
            ? [:]
            : await PTVStopIDResolver.shared.ptvStopIds(
                for: favourites,
                routeType: routeType,
                provider: provider
              )

        let nearbyIds = stops.map(\.stopId)
        let boards = await departureBoards(forStopIds: nearbyIds + Array(idMap.values))

        let reference = CLLocation(latitude: referenceLatitude, longitude: referenceLongitude)

        let nearbyStops: [NearbyBusStop] = stops.compactMap { stop in
            guard let departures = boards.departures[stop.stopId], !departures.isEmpty else { return nil }
            let distance = stop.distanceMeters.map { Int($0) } ?? Int(reference.distance(
                from: CLLocation(latitude: stop.latitude, longitude: stop.longitude)
            ))
            return NearbyBusStop(
                id: String(stop.stopId),
                stopName: stop.stopName,
                stopCode: stop.stopLandmark,
                latitude: stop.latitude,
                longitude: stop.longitude,
                distanceMeters: distance,
                departures: departures
            )
        }

        let nearbyIdSet = Set(nearbyIds)
        let favouriteStops: [NearbyBusStop] = favourites.compactMap { favourite in
            guard let stopId = idMap[favourite.stopId], !nearbyIdSet.contains(stopId),
                  let departures = boards.departures[stopId], !departures.isEmpty
            else { return nil }

            let distance = Int(reference.distance(
                from: CLLocation(latitude: favourite.latitude, longitude: favourite.longitude)
            ))
            return NearbyBusStop(
                id: favourite.stopId,
                stopName: favourite.stopName,
                stopCode: favourite.stopCode,
                latitude: favourite.latitude,
                longitude: favourite.longitude,
                distanceMeters: distance,
                departures: departures
            )
        }

        return BusInfo(
            provider: provider,
            nearbyStops: nearbyStops,
            favouriteStops: favouriteStops,
            alerts: alerts(from: boards.disruptions),
            localTimeAtFetch: currentMelbourneTimeString(),
            locationAvailable: true
        )
    }

    // MARK: - Helpers

    // MARK: - Disruptions

    /// Disruptions ride along on the departures responses via `expand=Disruption`,
    /// so building alerts costs no extra requests.
    private func alerts(from disruptions: [PTVDisruption]) -> [BusAlert] {
        var seen: Set<Int> = []
        let severityRank: [BusAlertSeverity: Int] = [.severe: 0, .warning: 1, .info: 2]

        return disruptions
            .filter { $0.displayOnBoard && !$0.title.isEmpty }
            .filter { disruption in
                // Ignore anything that has already finished.
                guard let toDate = disruption.toDate else { return true }
                return toDate >= Date()
            }
            .filter { seen.insert($0.disruptionId).inserted }
            .map { disruption in
                BusAlert(
                    headerText: disruption.title,
                    descriptionText: Self.detail(of: disruption),
                    severity: severity(for: disruption),
                    effect: disruption.disruptionType.isEmpty ? "Service Alert" : disruption.disruptionType,
                    affectedRoutes: disruption.routes.map { String($0.routeId) },
                    affectedStops: disruption.stops.map { String($0.stopId) }
                )
            }
            .sorted { lhs, rhs in
                (severityRank[lhs.severity] ?? 3) < (severityRank[rhs.severity] ?? 3)
            }
    }

    /// PTV frequently repeats the title verbatim as the description, which would
    /// render the same sentence twice in the alert row.
    private static func detail(of disruption: PTVDisruption) -> String? {
        let title = disruption.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = disruption.description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty, body != title else { return nil }

        if body.hasPrefix(title) {
            let remainder = String(body.dropFirst(title.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        }
        return body
    }

    private func severity(for disruption: PTVDisruption) -> BusAlertSeverity {
        let type = disruption.disruptionType.lowercased()

        // A planned future closure is not as pressing as one happening now.
        let isPlanned = disruption.disruptionStatus.lowercased() == "planned"

        if type.contains("suspend") || type.contains("closure") || type.contains("cancel") {
            return isPlanned ? .warning : .severe
        }
        if type.contains("delay") || type.contains("works") || type.contains("detour")
            || type.contains("diversion") || type.contains("replace") {
            return isPlanned ? .info : .warning
        }
        return .info
    }

    private func status(for entry: PTVDeparture) -> BusDepartureStatus {
        guard let delay = entry.delaySeconds else { return .noData }
        if abs(delay) < 60 { return .onTime }
        return delay > 0 ? .late : .early
    }

    private func emptyBoard() -> BusInfo {
        BusInfo(
            provider: provider,
            nearbyStops: [],
            favouriteStops: [],
            alerts: [],
            localTimeAtFetch: currentMelbourneTimeString(),
            locationAvailable: true
        )
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = melbourneTimeZone
        return formatter.string(from: date)
    }

    private func currentMelbourneTimeString() -> String {
        timeString(Date())
    }

    private func secondsSinceMelbourneMidnight(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourneTimeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
    }
}
