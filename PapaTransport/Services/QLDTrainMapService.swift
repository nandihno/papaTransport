import CoreLocation
import Foundation

final class QLDTrainMapService: BusDataProviding {
    static let shared = QLDTrainMapService()
    static let departureWindowSeconds = 2 * 60 * 60
    static let departureWindowDescription = "next 2 hours"

    private init() {}

    let provider: BusProvider = .queenslandTrainTransLink

    private let tripUpdatesURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates/Rail")!
    private let alertsURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/alerts")!
    private let brisbaneTimeZone = TimeZone(identifier: "Australia/Brisbane")!

    enum TrainDetailError: LocalizedError {
        case tripPatternUnavailable

        var errorDescription: String? {
            switch self {
            case .tripPatternUnavailable:
                return "The stop pattern for this train service is not available right now."
            }
        }
    }

    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo {
        try await GTFSDatabase.shared.ensureReady()

        let nearbyRaw = try await GTFSDatabase.shared.nearbyTrainStations(
            latitude: latitude,
            longitude: longitude,
            radiusMeters: 5000
        )
        return try await makeBoard(
            nearbyRaw: nearbyRaw,
            referenceLatitude: latitude,
            referenceLongitude: longitude,
            includeFavourites: true
        )
    }

    func fetchBusInfo(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        referenceLatitude: Double,
        referenceLongitude: Double
    ) async throws -> BusInfo {
        try await GTFSDatabase.shared.ensureReady()

        let nearbyRaw = try await GTFSDatabase.shared.trainStationsInRegion(
            minLat: minLat,
            maxLat: maxLat,
            minLon: minLon,
            maxLon: maxLon,
            referenceLatitude: referenceLatitude,
            referenceLongitude: referenceLongitude
        )

        return try await makeBoard(
            nearbyRaw: nearbyRaw,
            referenceLatitude: referenceLatitude,
            referenceLongitude: referenceLongitude,
            includeFavourites: false
        )
    }

    func fetchFavouriteBusInfo(referenceLatitude latitude: Double, longitude: Double) async throws -> BusInfo {
        try await GTFSDatabase.shared.ensureReady()

        let favourites = await MainActor.run { FavouriteBusStopStore.shared.favourites(for: provider) }
        let favouriteStopIds = favourites.map(\.stopId)
        guard !favouriteStopIds.isEmpty else {
            return BusInfo(
                provider: provider,
                nearbyStops: [],
                favouriteStops: [],
                alerts: [],
                localTimeAtFetch: currentBrisbaneTimeString(),
                locationAvailable: true
            )
        }

        let favouriteSiblingMap = try await siblingMap(for: favouriteStopIds)
        let allFavouriteStopIds = Array(Set(favouriteSiblingMap.values.flatMap(\.self)))

        let nowSeconds = GTFSDatabase.brisbaneMidnightSeconds()
        let cutoffSeconds = nowSeconds + Self.departureWindowSeconds

        async let tripUpdatesTask = fetchTripUpdates()
        async let railAlertsTask = fetchRailAlerts()
        let scheduledDepartures = try await GTFSDatabase.shared.trainDepartures(
            forStopIds: allFavouriteStopIds,
            afterSeconds: nowSeconds,
            untilSeconds: cutoffSeconds
        )
        let tripUpdates = await tripUpdatesTask
        let railAlerts = await railAlertsTask
        let stopDepartureMap = buildDepartureBoard(
            scheduled: scheduledDepartures,
            tripUpdates: tripUpdates,
            nowSeconds: nowSeconds
        )

        let userLocation = CLLocation(latitude: latitude, longitude: longitude)
        let favouriteStops: [NearbyBusStop] = favourites.compactMap { favourite in
            let siblings = favouriteSiblingMap[favourite.stopId] ?? [favourite.stopId]
            let departures = departuresWithinWindow(
                siblings.flatMap { stopDepartureMap[$0] ?? [] },
                from: nowSeconds,
                through: cutoffSeconds
            )
            guard !departures.isEmpty else { return nil }

            let stopLocation = CLLocation(latitude: favourite.latitude, longitude: favourite.longitude)
            let distance = Int(userLocation.distance(from: stopLocation))

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
            alerts: railAlerts,
            localTimeAtFetch: currentBrisbaneTimeString(),
            locationAvailable: true
        )
    }

    func fetchTripDetail(
        for departure: BusDeparture,
        stopId: String
    ) async throws -> BusTripDetail {
        try await GTFSDatabase.shared.ensureReady()

        async let tripUpdatesTask = fetchTripUpdates()
        let pattern = try await GTFSDatabase.shared.trainTripPattern(tripId: departure.tripId)
        let tripUpdates = await tripUpdatesTask

        guard !pattern.isEmpty else {
            throw TrainDetailError.tripPatternUnavailable
        }

        guard let selectedIndex =
            pattern.firstIndex(where: { $0.stopSequence == departure.stopSequence && $0.stopId == stopId })
            ?? pattern.firstIndex(where: { $0.stopSequence == departure.stopSequence })
            ?? pattern.firstIndex(where: { $0.stopId == stopId })
        else {
            throw TrainDetailError.tripPatternUnavailable
        }

        let selectedStop = pattern[selectedIndex]
        let tripUpdate = tripUpdates[departure.tripId]
        let trailingStops = pattern[selectedIndex...].map { stop in
            let scheduledSecs = scheduledSeconds(for: stop)
            let realtime = realtimeStopDetail(for: stop, tripUpdate: tripUpdate)

            return BusTripStopDetail(
                stopId: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                latitude: stop.stopLat,
                longitude: stop.stopLon,
                scheduledTime: scheduledSecs.map(secondsToTimeString),
                predictedTime: realtime.predictedTime,
                delaySeconds: realtime.delaySeconds,
                status: realtime.status,
                stopSequence: stop.stopSequence,
                isSelectedStop: stop.stopSequence == selectedStop.stopSequence && stop.stopId == selectedStop.stopId
            )
        }

        guard let terminalStop = trailingStops.last else {
            throw TrainDetailError.tripPatternUnavailable
        }

        return BusTripDetail(
            tripId: departure.tripId,
            routeShortName: departure.routeShortName,
            routeLongName: departure.routeLongName,
            headsign: departure.headsign,
            selectedStopName: selectedStop.stopName,
            selectedStopSequence: selectedStop.stopSequence,
            earlierStopCount: selectedIndex,
            remainingStopCount: max(0, trailingStops.count - 1),
            terminalStopName: terminalStop.stopName,
            terminalScheduledTime: terminalStop.scheduledTime,
            terminalPredictedTime: terminalStop.predictedTime,
            stopsFromSelected: trailingStops
        )
    }

    // MARK: - GTFS-RT (no auth needed for TransLink)

    /// Fetches the SEQ alerts feed and returns only currently-active rail alerts
    /// (informed entities with routeType == 2, or network-wide alerts with no specific filter).
    private func fetchRailAlerts() async -> [BusAlert] {
        do {
            let (data, _) = try await URLSession.shared.data(from: alertsURL)
            let feed = try GTFSRTFeedMessage(data: data)
            let rawAlerts = feed.entities.compactMap(\.alert)
            let now = UInt64(Date().timeIntervalSince1970)

            return rawAlerts.compactMap { alert -> BusAlert? in
                // Must be currently active
                if !alert.activePeriods.isEmpty {
                    let isActive = alert.activePeriods.contains {
                        ($0.start == 0 || $0.start <= now) && ($0.end == 0 || $0.end >= now)
                    }
                    guard isActive else { return nil }
                }

                // Keep alerts that explicitly target rail (routeType == 2) or are
                // network-wide (no routeType / routeId / stopId restrictions).
                let isRailAlert = alert.informedEntities.contains {
                    $0.routeType == 2
                }
                let isNetworkWide = alert.informedEntities.contains {
                    $0.routeType == nil && $0.routeId == nil && $0.stopId == nil
                }
                guard isRailAlert || isNetworkWide else { return nil }
                guard let header = alert.headerText, !header.isEmpty else { return nil }

                let severity: BusAlertSeverity
                switch alert.severityLevel {
                case .severe:  severity = .severe
                case .warning: severity = .warning
                default:       severity = .info
                }

                let effectStr: String
                switch alert.effect {
                case .noService:         effectStr = "No Service"
                case .reducedService:    effectStr = "Reduced Service"
                case .significantDelays: effectStr = "Significant Delays"
                case .detour:            effectStr = "Detour"
                case .modifiedService:   effectStr = "Modified Service"
                default:                 effectStr = "Service Alert"
                }

                return BusAlert(
                    headerText: header,
                    descriptionText: alert.descriptionText,
                    severity: severity,
                    effect: effectStr,
                    affectedRoutes: alert.informedEntities.compactMap(\.routeId),
                    affectedStops: alert.informedEntities.compactMap(\.stopId)
                )
            }
        } catch {
            return []
        }
    }

    private func fetchTripUpdates() async -> [String: GTFSRTTripUpdate] {
        do {
            let (data, _) = try await URLSession.shared.data(from: tripUpdatesURL)
            let feed = try GTFSRTFeedMessage(data: data)
            var byTripId: [String: GTFSRTTripUpdate] = [:]
            for entity in feed.entities {
                if let tripUpdate = entity.tripUpdate, !tripUpdate.tripId.isEmpty {
                    byTripId[tripUpdate.tripId] = tripUpdate
                }
            }
            return byTripId
        } catch {
            return [:]
        }
    }

    // MARK: - Departure board

    private func buildDepartureBoard(
        scheduled: [GTFSDatabase.ScheduledDeparture],
        tripUpdates: [String: GTFSRTTripUpdate],
        nowSeconds: Int
    ) -> [String: [BusDeparture]] {
        var result: [String: [BusDeparture]] = [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = brisbaneTimeZone

        for departure in scheduled {
            let tripUpdate = tripUpdates[departure.tripId]
            let stopTimeUpdate = tripUpdate?.stopTimeUpdates.first { update in
                (!update.stopId.isEmpty && update.stopId == departure.stopId)
                    || (update.stopSequence > 0 && Int(update.stopSequence) == departure.stopSequence)
            }

            let delaySeconds: Int
            let predictedTime: String?
            let status: BusDepartureStatus

            if let stopTimeUpdate {
                switch stopTimeUpdate.scheduleRelationship {
                case .skipped:
                    continue
                case .noData:
                    if let tripDelay = tripUpdate?.delay {
                        delaySeconds = Int(tripDelay)
                        predictedTime = secondsToTimeString(departure.departureSeconds + Int(tripDelay))
                        status = statusForDelay(delaySeconds)
                    } else {
                        delaySeconds = 0
                        predictedTime = nil
                        status = .noData
                    }
                default:
                    if let departureEvent = stopTimeUpdate.departure {
                        delaySeconds = Int(departureEvent.delay)
                        if departureEvent.time > 0 {
                            let predictedDate = Date(timeIntervalSince1970: TimeInterval(departureEvent.time))
                            predictedTime = formatter.string(from: predictedDate)
                        } else {
                            predictedTime = secondsToTimeString(departure.departureSeconds + Int(departureEvent.delay))
                        }
                        status = statusForDelay(delaySeconds)
                    } else if let arrivalEvent = stopTimeUpdate.arrival {
                        delaySeconds = Int(arrivalEvent.delay)
                        predictedTime = secondsToTimeString(departure.departureSeconds + Int(arrivalEvent.delay))
                        status = statusForDelay(delaySeconds)
                    } else if let tripDelay = tripUpdate?.delay {
                        delaySeconds = Int(tripDelay)
                        predictedTime = secondsToTimeString(departure.departureSeconds + Int(tripDelay))
                        status = statusForDelay(delaySeconds)
                    } else {
                        delaySeconds = 0
                        predictedTime = nil
                        status = .noData
                    }
                }
            } else if let tripDelay = tripUpdate?.delay {
                delaySeconds = Int(tripDelay)
                predictedTime = secondsToTimeString(departure.departureSeconds + Int(tripDelay))
                status = statusForDelay(delaySeconds)
            } else {
                delaySeconds = 0
                predictedTime = nil
                status = .noData
            }

            let effectiveDepartureSeconds = departure.departureSeconds + delaySeconds
            let minutesAway = max(0, (effectiveDepartureSeconds - nowSeconds) / 60)

            let busDeparture = BusDeparture(
                tripId: departure.tripId,
                routeShortName: departure.routeShortName,
                routeLongName: departure.routeLongName,
                headsign: departure.tripHeadsign,
                scheduledTime: secondsToTimeString(departure.departureSeconds),
                scheduledSeconds: departure.departureSeconds,
                predictedTime: predictedTime,
                delaySeconds: delaySeconds,
                minutesAway: minutesAway,
                status: status,
                stopSequence: departure.stopSequence
            )

            result[departure.stopId, default: []].append(busDeparture)
        }

        return result
    }

    // MARK: - Helpers

    private func makeBoard(
        nearbyRaw: [(stop: GTFSStop, distanceMeters: Double)],
        referenceLatitude: Double,
        referenceLongitude: Double,
        includeFavourites: Bool
    ) async throws -> BusInfo {
        let nearbyStopIds = nearbyRaw.map { $0.stop.stopId }
        let nearbySiblingMap = try await siblingMap(for: nearbyStopIds)
        let allNearbyStopIds = Array(Set(nearbySiblingMap.values.flatMap(\.self)))

        let favourites: [FavouriteBusStop]
        let favouriteSiblingMap: [String: [String]]
        let allFavouriteStopIds: [String]

        if includeFavourites {
            favourites = await MainActor.run { FavouriteBusStopStore.shared.favourites(for: provider) }
            let favouriteStopIds = favourites.map(\.stopId)
            favouriteSiblingMap = try await siblingMap(for: favouriteStopIds)
            allFavouriteStopIds = Array(Set(favouriteSiblingMap.values.flatMap(\.self)))
        } else {
            favourites = []
            favouriteSiblingMap = [:]
            allFavouriteStopIds = []
        }

        let allStopIds = Array(Set(allNearbyStopIds + allFavouriteStopIds))

        let nowSeconds = GTFSDatabase.brisbaneMidnightSeconds()
        let cutoffSeconds = nowSeconds + Self.departureWindowSeconds

        // Run DB query and GTFS-RT network fetches concurrently
        async let tripUpdatesTask = fetchTripUpdates()
        async let railAlertsTask = fetchRailAlerts()
        let scheduledDepartures: [GTFSDatabase.ScheduledDeparture]
        if allStopIds.isEmpty {
            scheduledDepartures = []
        } else {
            scheduledDepartures = try await GTFSDatabase.shared.trainDepartures(
                forStopIds: allStopIds,
                afterSeconds: nowSeconds,
                untilSeconds: cutoffSeconds
            )
        }
        let tripUpdates = await tripUpdatesTask
        let railAlerts = await railAlertsTask

        let stopDepartureMap = buildDepartureBoard(
            scheduled: scheduledDepartures,
            tripUpdates: tripUpdates,
            nowSeconds: nowSeconds
        )

        let nearbyStops: [NearbyBusStop] = nearbyRaw.compactMap { stop, distance in
            let siblings = nearbySiblingMap[stop.stopId] ?? [stop.stopId]
            let departures = departuresWithinWindow(
                siblings.flatMap { stopDepartureMap[$0] ?? [] },
                from: nowSeconds,
                through: cutoffSeconds
            )
            guard !departures.isEmpty else { return nil }
            return NearbyBusStop(
                id: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                latitude: stop.stopLat,
                longitude: stop.stopLon,
                distanceMeters: Int(distance),
                departures: departures
            )
        }

        let favouriteStops: [NearbyBusStop]
        if includeFavourites {
            let nearbyStopIdSet = Set(nearbyStopIds)
            let userLocation = CLLocation(latitude: referenceLatitude, longitude: referenceLongitude)
            favouriteStops = favourites.compactMap { favourite in
                guard !nearbyStopIdSet.contains(favourite.stopId) else { return nil }
                let siblings = favouriteSiblingMap[favourite.stopId] ?? [favourite.stopId]
                let departures = departuresWithinWindow(
                    siblings.flatMap { stopDepartureMap[$0] ?? [] },
                    from: nowSeconds,
                    through: cutoffSeconds
                )
                guard !departures.isEmpty else { return nil }

                let stopLocation = CLLocation(latitude: favourite.latitude, longitude: favourite.longitude)
                let distance = Int(userLocation.distance(from: stopLocation))

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
        } else {
            favouriteStops = []
        }

        return BusInfo(
            provider: provider,
            nearbyStops: nearbyStops,
            favouriteStops: favouriteStops,
            alerts: railAlerts,
            localTimeAtFetch: currentBrisbaneTimeString(),
            locationAvailable: true
        )
    }

    private func siblingMap(for stopIds: [String]) async throws -> [String: [String]] {
        try await GTFSDatabase.shared.trainSiblingMap(for: Set(stopIds))
    }

    private func departuresWithinWindow(
        _ departures: [BusDeparture],
        from nowSeconds: Int,
        through cutoffSeconds: Int
    ) -> [BusDeparture] {
        departures
            .filter { $0.scheduledSeconds >= nowSeconds && $0.scheduledSeconds <= cutoffSeconds }
            .sorted { $0.scheduledSeconds < $1.scheduledSeconds }
    }

    private func statusForDelay(_ delaySeconds: Int) -> BusDepartureStatus {
        if abs(delaySeconds) < 60 { return .onTime }
        return delaySeconds > 0 ? .late : .early
    }

    private func currentBrisbaneTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = brisbaneTimeZone
        return formatter.string(from: Date())
    }

    private func scheduledSeconds(for stop: GTFSDatabase.TripPatternStop) -> Int? {
        if stop.departureSeconds > 0 { return stop.departureSeconds }
        if stop.arrivalSeconds > 0 { return stop.arrivalSeconds }
        return nil
    }

    private func realtimeStopDetail(
        for stop: GTFSDatabase.TripPatternStop,
        tripUpdate: GTFSRTTripUpdate?
    ) -> TripPatternRealtimeDetail {
        guard let tripUpdate else { return TripPatternRealtimeDetail() }

        let stopTimeUpdate = tripUpdate.stopTimeUpdates.first { update in
            (!update.stopId.isEmpty && update.stopId == stop.stopId)
                || (update.stopSequence > 0 && Int(update.stopSequence) == stop.stopSequence)
        }

        if let stopTimeUpdate {
            switch stopTimeUpdate.scheduleRelationship {
            case .skipped:
                return TripPatternRealtimeDetail(status: .skipped)
            case .noData:
                if let tripDelay = tripUpdate.delay {
                    let delay = Int(tripDelay)
                    guard delay != 0 else { return TripPatternRealtimeDetail() }
                    return TripPatternRealtimeDetail(
                        predictedTime: predictedTime(for: stop, eventTime: nil, delaySeconds: delay),
                        delaySeconds: delay,
                        status: statusForDelay(delay)
                    )
                }
                return TripPatternRealtimeDetail()
            default:
                if let departureEvent = stopTimeUpdate.departure {
                    let delay = Int(departureEvent.delay)
                    return TripPatternRealtimeDetail(
                        predictedTime: predictedTime(
                            for: stop,
                            eventTime: departureEvent.time > 0 ? Int(departureEvent.time) : nil,
                            delaySeconds: delay
                        ),
                        delaySeconds: delay,
                        status: statusForDelay(delay)
                    )
                }
                if let arrivalEvent = stopTimeUpdate.arrival {
                    let delay = Int(arrivalEvent.delay)
                    return TripPatternRealtimeDetail(
                        predictedTime: predictedTime(
                            for: stop,
                            eventTime: arrivalEvent.time > 0 ? Int(arrivalEvent.time) : nil,
                            delaySeconds: delay
                        ),
                        delaySeconds: delay,
                        status: statusForDelay(delay)
                    )
                }
                if let tripDelay = tripUpdate.delay {
                    let delay = Int(tripDelay)
                    guard delay != 0 else { return TripPatternRealtimeDetail() }
                    return TripPatternRealtimeDetail(
                        predictedTime: predictedTime(for: stop, eventTime: nil, delaySeconds: delay),
                        delaySeconds: delay,
                        status: statusForDelay(delay)
                    )
                }
                return TripPatternRealtimeDetail()
            }
        }

        if let tripDelay = tripUpdate.delay {
            let delay = Int(tripDelay)
            guard delay != 0 else { return TripPatternRealtimeDetail() }
            return TripPatternRealtimeDetail(
                predictedTime: predictedTime(for: stop, eventTime: nil, delaySeconds: delay),
                delaySeconds: delay,
                status: statusForDelay(delay)
            )
        }

        return TripPatternRealtimeDetail()
    }

    private func predictedTime(
        for stop: GTFSDatabase.TripPatternStop,
        eventTime: Int?,
        delaySeconds: Int
    ) -> String? {
        if let eventTime {
            let predictedDate = Date(timeIntervalSince1970: TimeInterval(eventTime))
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.timeZone = brisbaneTimeZone
            return formatter.string(from: predictedDate)
        }
        guard let scheduledSecs = scheduledSeconds(for: stop) else { return nil }
        return secondsToTimeString(scheduledSecs + delaySeconds)
    }

    private func secondsToTimeString(_ totalSeconds: Int) -> String {
        let safeSeconds = max(0, totalSeconds)
        let hours = (safeSeconds / 3600) % 24
        let minutes = (safeSeconds % 3600) / 60
        let ampm = hours >= 12 ? "PM" : "AM"
        let displayHour = hours == 0 ? 12 : (hours > 12 ? hours - 12 : hours)
        return String(format: "%d:%02d %@", displayHour, minutes, ampm)
    }
}

private struct TripPatternRealtimeDetail {
    var predictedTime: String? = nil
    var delaySeconds: Int? = nil
    var status: BusDepartureStatus? = nil
}
