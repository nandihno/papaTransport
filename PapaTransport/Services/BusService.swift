//
//  BusService.swift
//  myLatest
//
//  Fetches and combines SEQ GTFS static data + GTFS-RT real-time data
//  to produce a bus departure board based on user location.
//
//  Data sources:
//  - Static: SEQ_GTFS.zip (stops, routes, trips, stop_times, calendar)
//  - Real-time: TransLink GTFS-RT (TripUpdates/Bus, alerts)
//

import Foundation
import CoreLocation

final class BusService: BusDataProviding {
    static let shared = BusService()

    enum TripDetailError: LocalizedError {
        case tripPatternUnavailable

        var errorDescription: String? {
            switch self {
            case .tripPatternUnavailable:
                return "The stop pattern for this trip is not available right now."
            }
        }
    }

    private init() {}

    let provider: BusProvider = .queenslandTransLink

    // MARK: - GTFS-RT Endpoints (Bus-specific for smaller payloads)

    private let tripUpdatesURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates/Bus")!
    private let alertsURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/alerts")!

    private let brisbaneTimeZone = TimeZone(identifier: "Australia/Brisbane")!

    // MARK: - Public API

    /// Fetch bus departure info for stops near the given location.
    /// This method orchestrates: GTFS DB readiness → nearby stops → schedule → RT overlay → alerts.
    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo {
        // 1. Ensure GTFS database is ready
        try await GTFSDatabase.shared.ensureReady()

        // 2. Find nearby bus stops (within 300m)
        let nearbyRaw = try await GTFSDatabase.shared.nearbyBusStops(
            latitude: latitude, longitude: longitude, radiusMeters: 300
        )

        let nearbyStopIds = nearbyRaw.map { $0.stop.stopId }

        // 3. Favourite stops
        let favourites = await MainActor.run { FavouriteBusStopStore.shared.favourites(for: provider) }
        let favStopIds = favourites.map(\.stopId)

        // Combine all stop IDs (deduplicate)
        let allStopIds = Array(Set(nearbyStopIds + favStopIds))

        // 4. Get scheduled departures from now
        let nowSeconds = GTFSDatabase.brisbaneMidnightSeconds()
        var scheduledDepartures: [GTFSDatabase.ScheduledDeparture] = []
        if !allStopIds.isEmpty {
            scheduledDepartures = try await GTFSDatabase.shared.departures(
                forStopIds: allStopIds, afterSeconds: nowSeconds, limitPerStop: 15
            )
        }

        // 5. Fetch GTFS-RT data concurrently
        async let tripUpdatesTask = fetchTripUpdates()
        async let alertsTask = fetchAlerts()

        let tripUpdates = await tripUpdatesTask
        let rawAlerts = await alertsTask

        // 6. Build the departure board
        let stopDepartureMap = buildDepartureBoard(
            scheduled: scheduledDepartures,
            tripUpdates: tripUpdates,
            nowSeconds: nowSeconds
        )

        // 7. Assemble NearbyBusStop models (proximity-based)
        let nearbyStops: [NearbyBusStop] = nearbyRaw.compactMap { (stop, distance) in
            let departures = stopDepartureMap[stop.stopId] ?? []
            guard !departures.isEmpty else { return nil }
            return NearbyBusStop(
                id: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                distanceMeters: Int(distance),
                departures: departures
            )
        }

        // 8. Assemble favourite stops (not already in nearby)
        let nearbyIdSet = Set(nearbyStopIds)
        let favouriteStops: [NearbyBusStop] = favourites.compactMap { fav in
            // Skip if already showing as nearby
            guard !nearbyIdSet.contains(fav.stopId) else { return nil }
            let departures = stopDepartureMap[fav.stopId] ?? []
            guard !departures.isEmpty else { return nil }

            // Calculate distance from user
            let stopLocation = CLLocation(latitude: fav.latitude, longitude: fav.longitude)
            let userLocation = CLLocation(latitude: latitude, longitude: longitude)
            let dist = Int(userLocation.distance(from: stopLocation))

            return NearbyBusStop(
                id: fav.stopId,
                stopName: fav.stopName,
                stopCode: fav.stopCode,
                distanceMeters: dist,
                departures: departures
            )
        }

        // 9. Filter alerts relevant to all stops/routes
        let relevantRouteIds = Set(scheduledDepartures.map(\.routeId))
        let relevantStopIds = Set(allStopIds)
        let filteredAlerts = filterAlerts(rawAlerts, stopIds: relevantStopIds, routeIds: relevantRouteIds)

        return BusInfo(
            provider: provider,
            nearbyStops: nearbyStops,
            favouriteStops: favouriteStops,
            alerts: filteredAlerts,
            localTimeAtFetch: currentBrisbaneTimeString(),
            locationAvailable: true
        )
    }

    func fetchTripDetail(
        for departure: BusDeparture,
        stopId: String
    ) async throws -> BusTripDetail {
        try await GTFSDatabase.shared.ensureReady()

        let pattern = try await GTFSDatabase.shared.tripPattern(tripId: departure.tripId)
        guard !pattern.isEmpty else {
            throw TripDetailError.tripPatternUnavailable
        }

        guard let selectedIndex =
            pattern.firstIndex(where: { $0.stopSequence == departure.stopSequence && $0.stopId == stopId })
            ?? pattern.firstIndex(where: { $0.stopSequence == departure.stopSequence })
            ?? pattern.firstIndex(where: { $0.stopId == stopId })
        else {
            throw TripDetailError.tripPatternUnavailable
        }

        let selectedStop = pattern[selectedIndex]
        let trailingStops = pattern[selectedIndex...].map { stop in
            let scheduledSeconds: Int? = {
                if stop.departureSeconds > 0 { return stop.departureSeconds }
                if stop.arrivalSeconds > 0 { return stop.arrivalSeconds }
                return nil
            }()

            return BusTripStopDetail(
                stopId: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                latitude: stop.stopLat,
                longitude: stop.stopLon,
                scheduledTime: scheduledSeconds.map(secondsToTimeString),
                predictedTime: nil,
                delaySeconds: nil,
                status: nil,
                stopSequence: stop.stopSequence,
                isSelectedStop: stop.stopSequence == selectedStop.stopSequence && stop.stopId == selectedStop.stopId
            )
        }

        guard let terminalStop = trailingStops.last else {
            throw TripDetailError.tripPatternUnavailable
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
            terminalPredictedTime: nil,
            stopsFromSelected: trailingStops
        )
    }

    // MARK: - GTFS-RT fetching

    private func fetchTripUpdates() async -> [String: GTFSRTTripUpdate] {
        do {
            let (data, _) = try await URLSession.shared.data(from: tripUpdatesURL)
            let feed = try GTFSRTFeedMessage(data: data)

            var byTripId: [String: GTFSRTTripUpdate] = [:]
            for entity in feed.entities {
                if let tu = entity.tripUpdate {
                    byTripId[tu.tripId] = tu
                }
            }
            return byTripId
        } catch {
            print("⚠️ GTFS-RT TripUpdates fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private func fetchAlerts() async -> [GTFSRTAlert] {
        do {
            let (data, _) = try await URLSession.shared.data(from: alertsURL)
            let feed = try GTFSRTFeedMessage(data: data)
            return feed.entities.compactMap(\.alert)
        } catch {
            print("⚠️ GTFS-RT Alerts fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Combine static + real-time

    private func buildDepartureBoard(
        scheduled: [GTFSDatabase.ScheduledDeparture],
        tripUpdates: [String: GTFSRTTripUpdate],
        nowSeconds: Int
    ) -> [String: [BusDeparture]] {
        var result: [String: [BusDeparture]] = [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = brisbaneTimeZone

        for dep in scheduled {
            let tripUpdate = tripUpdates[dep.tripId]
            let stopTimeUpdate = tripUpdate?.stopTimeUpdates.first(where: { $0.stopId == dep.stopId })

            // Determine real-time prediction
            let delaySeconds: Int
            let predictedTime: String?
            let status: BusDepartureStatus

            if let stu = stopTimeUpdate {
                switch stu.scheduleRelationship {
                case .skipped:
                    continue  // skip this departure — bus won't stop here
                case .noData:
                    delaySeconds = 0
                    predictedTime = nil
                    status = .noData
                default:
                    if let depEvent = stu.departure {
                        delaySeconds = Int(depEvent.delay)
                        if depEvent.time > 0 {
                            let predDate = Date(timeIntervalSince1970: TimeInterval(depEvent.time))
                            predictedTime = formatter.string(from: predDate)
                        } else {
                            // Calculate from scheduled + delay
                            let predSeconds = dep.departureSeconds + Int(depEvent.delay)
                            predictedTime = secondsToTimeString(predSeconds)
                        }
                        if abs(delaySeconds) < 60 {
                            status = .onTime
                        } else if delaySeconds > 0 {
                            status = .late
                        } else {
                            status = .early
                        }
                    } else if let arrEvent = stu.arrival {
                        delaySeconds = Int(arrEvent.delay)
                        predictedTime = nil
                        status = abs(delaySeconds) < 60 ? .onTime : (delaySeconds > 0 ? .late : .early)
                    } else {
                        delaySeconds = 0
                        predictedTime = nil
                        status = .noData
                    }
                }
            } else {
                delaySeconds = 0
                predictedTime = nil
                status = .noData
            }

            let effectiveDepartureSeconds = dep.departureSeconds + delaySeconds
            let minutesAway = max(0, (effectiveDepartureSeconds - nowSeconds) / 60)

            let busDep = BusDeparture(
                tripId: dep.tripId,
                routeShortName: dep.routeShortName,
                routeLongName: dep.routeLongName,
                headsign: dep.tripHeadsign,
                scheduledTime: secondsToTimeString(dep.departureSeconds),
                scheduledSeconds: dep.departureSeconds,
                predictedTime: predictedTime,
                delaySeconds: delaySeconds,
                minutesAway: minutesAway,
                status: status,
                stopSequence: dep.stopSequence
            )

            result[dep.stopId, default: []].append(busDep)
        }

        return result
    }

    // MARK: - Alert filtering

    private func filterAlerts(_ alerts: [GTFSRTAlert], stopIds: Set<String>, routeIds: Set<String>) -> [BusAlert] {
        let now = UInt64(Date().timeIntervalSince1970)

        return alerts.compactMap { alert -> BusAlert? in
            // Check if alert is currently active
            if !alert.activePeriods.isEmpty {
                let isActive = alert.activePeriods.contains { period in
                    (period.start == 0 || period.start <= now) &&
                    (period.end == 0 || period.end >= now)
                }
                guard isActive else { return nil }
            }

            // Check if alert affects our stops/routes
            let affectedRoutes = alert.informedEntities.compactMap(\.routeId)
            let affectedStops = alert.informedEntities.compactMap(\.stopId)

            let relevant = affectedStops.contains(where: { stopIds.contains($0) }) ||
                          affectedRoutes.contains(where: { routeIds.contains($0) }) ||
                          alert.informedEntities.contains(where: { $0.routeType == 3 && $0.routeId == nil && $0.stopId == nil })

            guard relevant else { return nil }
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
            case .stopMoved:         effectStr = "Stop Moved"
            default:                 effectStr = "Service Alert"
            }

            return BusAlert(
                headerText: header,
                descriptionText: alert.descriptionText,
                severity: severity,
                effect: effectStr,
                affectedRoutes: affectedRoutes,
                affectedStops: affectedStops
            )
        }
    }

    // MARK: - Time helpers

    private func currentBrisbaneTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = brisbaneTimeZone
        return formatter.string(from: Date())
    }

    private func secondsToTimeString(_ totalSeconds: Int) -> String {
        let hours = (totalSeconds / 3600) % 24
        let minutes = (totalSeconds % 3600) / 60
        let ampm = hours >= 12 ? "PM" : "AM"
        let displayHour = hours == 0 ? 12 : (hours > 12 ? hours - 12 : hours)
        return String(format: "%d:%02d %@", displayHour, minutes, ampm)
    }
}
