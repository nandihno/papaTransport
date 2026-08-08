//
//  PTVBoardService.swift
//  PapaTransport
//
//  Builds the stop/station departure board from the PTV Timetable API,
//  mapping onto the same `BusInfo` models the GTFS-backed services produce so
//  the UI is unchanged.
//
//  One instance per mode: PTV differs only by route_type between Victorian
//  train and Victorian bus. A mode may span more than one route type — the
//  train board covers both metropolitan trains and V/Line.
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
    ///
    /// Victorian train stations are served by two PTV route types: metropolitan
    /// trains (0) and V/Line regional trains (3). A station board that showed
    /// only the first would silently drop every country service calling there.
    static let victorianTrain = PTVBoardService(
        routeTypes: [.train, .vline],
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
        routeTypes: [.bus],
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
        routeTypes: [.tram],
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

    /// Every route type this board draws from. Departures are fetched once per
    /// type and merged.
    private let routeTypes: [PTVRouteType]

    /// The type that identifies the mode — used where a single value is needed,
    /// such as resolving stored favourites onto PTV stop ids.
    private var primaryRouteType: PTVRouteType { routeTypes[0] }

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
        routeTypes: [PTVRouteType],
        provider: BusProvider,
        nearbyRadiusMeters: Int,
        fallbackRadiusMeters: Int,
        maxStops: Int,
        departureWindowSeconds: Int?,
        departuresPerRequest: Int,
        departuresPerLine: Int,
        maxDeparturesPerStop: Int
    ) {
        self.routeTypes = routeTypes
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
            routeType: primaryRouteType,
            provider: provider
        )
        let boards = await departureBoards(forStopIds: Array(idMap.values))
        let userLocation = CLLocation(latitude: latitude, longitude: longitude)

        let favouriteStops: [NearbyBusStop] = favourites.compactMap { favourite in
            guard let stopId = idMap[favourite.stopId] else { return nil }
            let departures = boards.departures[stopId] ?? []
            let departureDataAvailability: DepartureDataAvailability = boards.respondingStopIds.contains(stopId)
                ? .available
                : .unavailable
            guard !departures.isEmpty || departureDataAvailability == .unavailable else { return nil }

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
                departures: departures,
                departureDataAvailability: departureDataAvailability
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
                PTVEndpoint.pattern(
                    runRef: departure.tripId,
                    // The run reference alone does not say which route type it
                    // belongs to, and the pattern endpoint 404s on a mismatch.
                    routeType: departure.isRegional ? .vline : primaryRouteType
                ),
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
            stopsFromSelected: trailing,
            vehicleDescription: response.runs[departure.tripId]?
                .vehicleDescriptor?.displaySummary
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

    /// Only small requests are recorded as complete coverage. A wide PTV
    /// search can hit the server's 30-stop cap, so marking it as a complete
    /// cache tile would make a truncated response look authoritative.
    private static let maxCachedSweepRadiusMeters = 1_200

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
                    return await self.stops(
                        in: cell,
                        referenceLatitude: centre.coordinate.latitude,
                        referenceLongitude: centre.coordinate.longitude
                    )
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
        in cell: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        referenceLatitude: Double,
        referenceLongitude: Double
    ) async -> [PTVStop] {
        let centreLat = (cell.minLat + cell.maxLat) / 2
        let centreLon = (cell.minLon + cell.maxLon) / 2
        let centre = CLLocation(latitude: centreLat, longitude: centreLon)
        let corner = CLLocation(latitude: cell.maxLat, longitude: cell.maxLon)
        let radius = min(max(Int(centre.distance(from: corner).rounded()), 300), 30_000)

        let cacheKey = PTVStopCacheTileKey(
            latitude: centreLat,
            longitude: centreLon,
            radiusMeters: radius,
            routeTypes: routeTypes
        )
        let cache = PTVStopCache.shared
        let cached = await cache.lookup(
            minLatitude: cell.minLat,
            maxLatitude: cell.maxLat,
            minLongitude: cell.minLon,
            maxLongitude: cell.maxLon,
            referenceLatitude: referenceLatitude,
            referenceLongitude: referenceLongitude,
            routeTypes: routeTypes,
            coverageKeys: radius <= Self.maxCachedSweepRadiusMeters ? [cacheKey] : []
        )

        if radius <= Self.maxCachedSweepRadiusMeters, cached.missingCoverage.isEmpty {
            return Self.railStopsOnly(cached.stops)
        }

        do {
            let fetched = Self.railStopsOnly(try await PTVAPIClient.shared.get(
                PTVEndpoint.stopsNear(
                    latitude: centreLat,
                    longitude: centreLon,
                    routeTypes: routeTypes,
                    maxDistanceMeters: radius
                ),
                as: PTVStopsResponse.self,
                cacheFor: 120
            ).stops)

            await cache.store(
                fetched,
                swept: radius <= Self.maxCachedSweepRadiusMeters ? cached.missingCoverage : []
            )
            let merged = await cache.lookup(
                minLatitude: cell.minLat,
                maxLatitude: cell.maxLat,
                minLongitude: cell.minLon,
                maxLongitude: cell.maxLon,
                referenceLatitude: referenceLatitude,
                referenceLongitude: referenceLongitude,
                routeTypes: routeTypes,
                coverageKeys: []
            ).stops
            return Self.railStopsOnly(merged)
        } catch {
            print("⚠️ PTV stop search failed for region cell: \(error.localizedDescription)")
            return Self.railStopsOnly(cached.stops)
        }
    }

    /// Route type 3 covers V/Line road coaches as well as V/Line trains, and its
    /// coach stops are ordinary roadside stops — "Ballarat Station/Lydiard St",
    /// "Southern Cross Coach Terminal" — which have no place on a train board.
    ///
    /// V/Line *rail* stops are named "<Place> Railway Station" without exception
    /// in sweeps across Melbourne, Geelong, Ballarat, Bendigo and Gippsland;
    /// nothing else in the response distinguishes the two (the run's
    /// `vehicle_descriptor` is always null on this feed).
    ///
    /// A station served by both types shares one stop id between them, so the
    /// metro entry is preferred where there is a choice: "Footscray Station"
    /// reads better than "Footscray Railway Station".
    private static func railStopsOnly(_ stops: [PTVStop]) -> [PTVStop] {
        var byId: [Int: PTVStop] = [:]
        for stop in stops {
            guard stop.routeType != PTVRouteType.vline.rawValue
                    || stop.stopName.localizedCaseInsensitiveContains("railway station")
            else { continue }

            if let existing = byId[stop.stopId],
               existing.routeType != PTVRouteType.vline.rawValue {
                continue
            }
            byId[stop.stopId] = stop
        }
        return Array(byId.values)
    }

    // MARK: - Fetching

    private func nearbyStops(latitude: Double, longitude: Double, radius: Int) async throws -> [PTVStop] {
        func request(_ metres: Int) async throws -> [PTVStop] {
            let bounds = PTVStopCache.boundingBox(
                latitude: latitude,
                longitude: longitude,
                radiusMeters: metres
            )
            let cacheKey = PTVStopCacheTileKey(
                latitude: latitude,
                longitude: longitude,
                radiusMeters: metres,
                routeTypes: routeTypes
            )
            let cache = PTVStopCache.shared
            let cached = await cache.lookup(
                minLatitude: bounds.minLatitude,
                maxLatitude: bounds.maxLatitude,
                minLongitude: bounds.minLongitude,
                maxLongitude: bounds.maxLongitude,
                referenceLatitude: latitude,
                referenceLongitude: longitude,
                routeTypes: routeTypes,
                coverageKeys: [cacheKey],
                maxDistanceMeters: metres
            )

            if cached.missingCoverage.isEmpty {
                return Self.railStopsOnly(cached.stops)
            }

            do {
                let fetched = Self.railStopsOnly(try await PTVAPIClient.shared.get(
                PTVEndpoint.stopsNear(
                    latitude: latitude,
                    longitude: longitude,
                    routeTypes: routeTypes,
                    maxDistanceMeters: metres
                ),
                as: PTVStopsResponse.self,
                cacheFor: 120
                ).stops)
                await cache.store(fetched, swept: cached.missingCoverage)
                let merged = await cache.lookup(
                    minLatitude: bounds.minLatitude,
                    maxLatitude: bounds.maxLatitude,
                    minLongitude: bounds.minLongitude,
                    maxLongitude: bounds.maxLongitude,
                    referenceLatitude: latitude,
                    referenceLongitude: longitude,
                    routeTypes: routeTypes,
                    coverageKeys: [],
                    maxDistanceMeters: metres
                ).stops
                return Self.railStopsOnly(merged)
            } catch {
                // A previously persisted identity is still useful when PTV is
                // temporarily unavailable. Departures will make the final
                // availability decision for the board.
                if !cached.stops.isEmpty {
                    return Self.railStopsOnly(cached.stops)
                }
                throw error
            }
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
        var respondingStopIds: Set<Int> = []
        var disruptions: [PTVDisruption] = []
        /// Keyed by run ref so a vehicle serving several of the stops in view
        /// is drawn once, not once per stop.
        var vehicles: [String: LiveVehicle] = [:]
    }

    /// Fetches boards for several stops at once. `PTVAPIClient` caps how many
    /// of these actually run in parallel.
    private func departureBoards(forStopIds stopIds: [Int]) async -> StopBoards {
        guard !stopIds.isEmpty else { return StopBoards() }

        return await withTaskGroup(of: (Int, [BusDeparture], [PTVDisruption], [LiveVehicle], Bool).self) { group in
            for stopId in Set(stopIds) {
                group.addTask { [weak self] in
                    guard let self else { return (stopId, [], [], [], false) }
                    let board = await self.departures(forStopId: stopId)
                    return (stopId, board.departures, board.disruptions, board.vehicles, board.didReceiveResponse)
                }
            }
            var result = StopBoards()
            for await (stopId, departures, disruptions, vehicles, didReceiveResponse) in group {
                if !departures.isEmpty { result.departures[stopId] = departures }
                if didReceiveResponse { result.respondingStopIds.insert(stopId) }
                result.disruptions.append(contentsOf: disruptions)
                for vehicle in vehicles { result.vehicles[vehicle.id] = vehicle }
            }
            return result
        }
    }

    /// Departures for one stop across every route type this board covers.
    ///
    /// The caps apply per route type rather than to the merged list, so a
    /// station's twelve metro lines cannot crowd out its V/Line services or the
    /// other way round.
    private func departures(
        forStopId stopId: Int
    ) async -> (
        departures: [BusDeparture],
        disruptions: [PTVDisruption],
        vehicles: [LiveVehicle],
        didReceiveResponse: Bool
    ) {
        var departures: [BusDeparture] = []
        var disruptions: [PTVDisruption] = []
        var vehicles: [LiveVehicle] = []
        var didReceiveResponse = false

        for type in routeTypes {
            do {
                let response = try await PTVAPIClient.shared.get(
                    PTVEndpoint.departures(
                        routeType: type,
                        stopId: stopId,
                        maxResults: departuresPerRequest,
                        expand: Self.expansions(includingVehiclePosition: suppliesVehiclePositions)
                    ),
                    as: PTVDeparturesResponse.self
                )
                didReceiveResponse = true
                departures.append(contentsOf: busDepartures(from: response, routeType: type))
                disruptions.append(contentsOf: response.disruptions.values)
                if suppliesVehiclePositions {
                    vehicles.append(contentsOf: liveVehicles(from: response, routeType: type))
                }
            } catch {
                // A stop that exists for one route type need not exist for the
                // other, so one failure must not empty the whole board.
                print("⚠️ PTV \(type.displayName) departures failed for stop \(stopId): \(error.localizedDescription)")
            }
        }

        // Merged on time-until-departure rather than clock time: a 2-hour window
        // late at night spans midnight, where seconds-since-midnight wraps.
        return (
            departures.sorted { $0.minutesAway < $1.minutesAway },
            disruptions,
            vehicles,
            didReceiveResponse
        )
    }

    /// Trams are excluded: measured 2026-07-31, 0 of 55 tram runs across four
    /// separate corridors carried a `vehicle_position`, so asking for the
    /// expansion would only make the response bigger.
    private var suppliesVehiclePositions: Bool {
        routeTypes.contains { $0 != .tram }
    }

    private static func expansions(includingVehiclePosition: Bool) -> [String] {
        let base = ["Route", "Direction", "Run", "Disruption"]
        return includingVehiclePosition ? base + ["VehiclePosition"] : base
    }

    /// Pulls live vehicles out of a departures response.
    ///
    /// Keyed by run, not by departure: several departures at a stop can belong
    /// to the same run, and the same vehicle must not be drawn twice.
    private func liveVehicles(
        from response: PTVDeparturesResponse,
        routeType: PTVRouteType
    ) -> [LiveVehicle] {
        response.runs.values.compactMap { run -> LiveVehicle? in
            guard let position = run.vehiclePosition,
                  position.isValidCoordinate,
                  position.isFresh()
            else { return nil }

            let route = response.routes[String(run.routeId)]
            let number = route?.routeNumber ?? ""
            let name = route?.routeName ?? ""

            return LiveVehicle(
                id: run.runRef,
                // PTV's run ref is exactly what BusDeparture stores as tripId,
                // so board matching is a direct lookup.
                tripId: run.runRef,
                latitude: position.latitude,
                longitude: position.longitude,
                bearing: position.bearing,
                routeLabel: number.isEmpty ? name : number,
                isRail: routeType == .train || routeType == .vline,
                isStopped: false
            )
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

    /// V/Line lists one physical train once per marketed through-journey, so the
    /// 07:53 Ballarat service appears at Southern Cross under eleven route ids
    /// with eleven run references. Two listings that leave the same stop at the
    /// same minute and finish at the same stop are the same train.
    ///
    /// The survivor is the one on a genuine rail line rather than a coach route
    /// that happens to share the rail leg, so the board says "Geelong" rather
    /// than "Warrnambool - Melbourne via Apollo Bay & Geelong".
    private func deduplicateRegional(
        _ upcoming: [UpcomingDeparture],
        response: PTVDeparturesResponse
    ) -> [UpcomingDeparture] {
        var bestForTrain: [String: (rank: Int, departure: UpcomingDeparture)] = [:]
        var order: [String] = []

        for departure in upcoming {
            let run = response.runs[String(departure.entry.runRef)]
            let key = "\(departure.when.timeIntervalSince1970)|\(run?.finalStopId ?? 0)"
            let gtfsId = response.routes[String(departure.entry.routeId)]?.routeGTFSId ?? ""
            let rank = Self.isRailLine(gtfsId) ? 0 : 1

            if let existing = bestForTrain[key] {
                if rank < existing.rank { bestForTrain[key] = (rank, departure) }
            } else {
                bestForTrain[key] = (rank, departure)
                order.append(key)
            }
        }

        return order.compactMap { bestForTrain[$0]?.departure }
    }

    /// V/Line rail lines carry a three-letter GTFS id under the `1-` prefix
    /// (`1-GEL`, `1-BAT`, `1-TRN`); coach routes are numbered (`1-V09`, `1-995`),
    /// lower-cased (`1-pay`) or sit under another prefix (`5-GCL`). Matching this
    /// picks out exactly the thirteen V/Line rail lines.
    private static func isRailLine(_ routeGTFSId: String) -> Bool {
        let parts = routeGTFSId.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0] == "1", parts[1].count == 3 else { return false }
        return parts[1].allSatisfy { $0.isUppercase && $0.isLetter }
    }

    private func busDepartures(
        from response: PTVDeparturesResponse,
        routeType: PTVRouteType
    ) -> [BusDeparture] {
        let now = Date()
        let cutoff = departureWindow.map { now.addingTimeInterval(TimeInterval($0)) }
        let isRegional = routeType == .vline

        var upcoming = response.departures
            .compactMap { entry -> UpcomingDeparture? in
                guard let when = entry.effectiveDeparture, when >= now else { return nil }
                if let cutoff, when > cutoff { return nil }
                return UpcomingDeparture(entry: entry, when: when)
            }
            .sorted { $0.when < $1.when }

        if isRegional {
            upcoming = deduplicateRegional(upcoming, response: response)
        }

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
                let destination = run?.destinationName.isEmpty == false
                    ? run?.destinationName
                    : direction?.directionName

                return BusDeparture(
                    tripId: entry.runRef,
                    // V/Line has no route number and its route names are whole
                    // journeys ("Geelong - Melbourne"), which make a poor badge.
                    // The operator name is the useful distinction on a board that
                    // mixes it with metro services; the line goes in the subtitle.
                    routeShortName: isRegional
                        ? "V/Line"
                        : (routeNumber.isEmpty ? routeName : routeNumber),
                    routeLongName: isRegional ? Self.regionalLineName(routeName) : routeName,
                    headsign: isRegional ? destination.map(Self.shortStationName) : destination,
                    scheduledTime: timeString(scheduled),
                    scheduledSeconds: secondsSinceMelbourneMidnight(scheduled),
                    predictedTime: entry.estimatedDeparture.map(timeString),
                    delaySeconds: entry.delaySeconds ?? 0,
                    minutesAway: max(0, Int(when.timeIntervalSince(now) / 60)),
                    status: status(for: entry),
                    stopSequence: entry.departureSequence,
                    platform: entry.platformNumber,
                    directionId: entry.directionId,
                    directionName: direction?.directionName,
                    expressStopCount: run?.expressStopCount ?? 0,
                    isAtPlatform: entry.atPlatform,
                    isRegional: isRegional
                )
            }
    }

    /// "Geelong - Melbourne" → "Geelong". V/Line names every route from the
    /// country end inwards, so the leading segment is the line as riders know it.
    private static func regionalLineName(_ routeName: String) -> String {
        // Split on the spaced hyphen: "Ballarat-Wendouree - Melbourne via Melton"
        // must keep its hyphenated place name intact.
        let line = routeName
            .components(separatedBy: " - ")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? routeName : line
    }

    /// V/Line destinations arrive as "Waurn Ponds Railway Station"; the suffix is
    /// noise in a row that is already on a train board.
    /// `nonisolated` so it can be passed by reference to `Optional.map`, which
    /// is itself nonisolated — see the note on default main-actor isolation in
    /// CLAUDE.md. It is a pure string transform with no state to protect.
    nonisolated private static func shortStationName(_ name: String) -> String {
        guard let range = name.range(of: " Railway Station", options: [.caseInsensitive, .backwards]),
              range.upperBound == name.endIndex
        else { return name }
        return String(name[..<range.lowerBound])
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
                routeType: primaryRouteType,
                provider: provider
              )

        let nearbyIds = stops.map(\.stopId)
        let boards = await departureBoards(forStopIds: nearbyIds + Array(idMap.values))

        let reference = CLLocation(latitude: referenceLatitude, longitude: referenceLongitude)

        let nearbyStops: [NearbyBusStop] = stops.compactMap { stop in
            let departures = boards.departures[stop.stopId] ?? []
            let departureDataAvailability: DepartureDataAvailability = boards.respondingStopIds.contains(stop.stopId)
                ? .available
                : .unavailable
            guard !departures.isEmpty || departureDataAvailability == .unavailable else { return nil }
            let distance = Int(reference.distance(
                from: CLLocation(latitude: stop.latitude, longitude: stop.longitude)
            ))
            return NearbyBusStop(
                id: String(stop.stopId),
                stopName: stop.stopName,
                stopCode: stop.stopLandmark,
                latitude: stop.latitude,
                longitude: stop.longitude,
                distanceMeters: distance,
                departures: departures,
                departureDataAvailability: departureDataAvailability
            )
        }

        let nearbyIdSet = Set(nearbyIds)
        let favouriteStops: [NearbyBusStop] = favourites.compactMap { favourite in
            guard let stopId = idMap[favourite.stopId], !nearbyIdSet.contains(stopId) else { return nil }
            let departures = boards.departures[stopId] ?? []
            let departureDataAvailability: DepartureDataAvailability = boards.respondingStopIds.contains(stopId)
                ? .available
                : .unavailable
            guard !departures.isEmpty || departureDataAvailability == .unavailable else { return nil }

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
                departures: departures,
                departureDataAvailability: departureDataAvailability
            )
        }

        return BusInfo(
            provider: provider,
            nearbyStops: nearbyStops,
            favouriteStops: favouriteStops,
            alerts: alerts(from: boards.disruptions),
            localTimeAtFetch: currentMelbourneTimeString(),
            locationAvailable: true,
            liveVehicles: Array(boards.vehicles.values)
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
