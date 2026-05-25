import CoreLocation
import Foundation
import MapKit

final class VictorianBusRoutePlannerService {
    static let shared = VictorianBusRoutePlannerService()

    private let maximumTransfers = 3
    private let minimumTransferSeconds = 5 * 60
    private let maximumJourneySeconds = 4 * 60 * 60
    private let legSearchHorizonSeconds = 45 * 60
    private let maximumStatesPerRound = 28

    enum PlannerError: LocalizedError {
        case noOriginStops
        case noDestinationStops

        var errorDescription: String? {
            switch self {
            case .noOriginStops:
                return "No Victorian bus stops were found near the starting point."
            case .noDestinationStops:
                return "No Victorian bus stops were found near the destination."
            }
        }
    }

    private init() {}

    func planDirectTrips(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> RoutePlanResult {
        try await planTrips(from: origin, to: destination)
    }

    func planTrips(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> RoutePlanResult {
        try await VictorianBusGTFSDatabase.shared.ensureReady()

        async let originStopsTask = VictorianBusGTFSDatabase.shared.routePlannerStopCandidates(
            latitude: origin.latitude,
            longitude: origin.longitude
        )
        async let destinationStopsTask = VictorianBusGTFSDatabase.shared.routePlannerStopCandidates(
            latitude: destination.latitude,
            longitude: destination.longitude
        )

        let originStops = try await mapStopCandidates(originStopsTask)
        let destinationStops = try await mapStopCandidates(destinationStopsTask)

        guard !originStops.isEmpty else { throw PlannerError.noOriginStops }
        guard !destinationStops.isEmpty else { throw PlannerError.noDestinationStops }

        let nowSeconds = VictorianBusGTFSDatabase.melbourneMidnightSeconds()
        let destinationById = Dictionary(uniqueKeysWithValues: destinationStops.map { ($0.stopId, $0) })
        let destinationStopIds = Set(destinationStops.map(\.stopId))
        let options = try await searchOptions(
            originStops: Array(originStops.prefix(5)),
            destinationStopIds: destinationStopIds,
            destinationById: destinationById,
            nowSeconds: nowSeconds
        )

        let enriched = await enrichWithWalkingDirections(bestOptions(from: options))
        return RoutePlanResult(
            originCandidates: originStops,
            destinationCandidates: destinationStops,
            options: enriched,
            generatedAt: Date()
        )
    }

    private func searchOptions(
        originStops: [RoutePlanStopCandidate],
        destinationStopIds: Set<String>,
        destinationById: [String: RoutePlanStopCandidate],
        nowSeconds: Int
    ) async throws -> [RoutePlanOption] {
        var completed: [RoutePlanOption] = []
        var frontier = originStops.map { stop in
            SearchState(
                currentStop: stop,
                arrivalSeconds: nowSeconds,
                legs: [],
                visitedStopIds: [stop.stopId],
                usedTripIds: []
            )
        }

        for _ in 0...maximumTransfers {
            guard !frontier.isEmpty else { break }
            var nextStates: [SearchState] = []
            var bestArrivalByStop: [String: Int] = [:]

            for state in frontier {
                // Determine all possible transfer points: current stop and nearby stops within 300m
                var transferPoints: [(stop: RoutePlanStopCandidate, distance: Double)] = []
                transferPoints.append((state.currentStop, 0.0))

                if !state.legs.isEmpty {
                    do {
                        let nearby = try await VictorianBusGTFSDatabase.shared.nearbyBusStops(
                            latitude: state.currentStop.latitude,
                            longitude: state.currentStop.longitude,
                            radiusMeters: 300.0
                        )
                        let candidates = nearby.filter { stop, _ in
                            stop.stopId != state.currentStop.stopId && !state.visitedStopIds.contains(stop.stopId)
                        }
                        for (stop, dist) in candidates.prefix(3) {
                            let candidate = RoutePlanStopCandidate(
                                stopId: stop.stopId,
                                stopName: stop.stopName,
                                stopCode: stop.stopCode,
                                latitude: stop.stopLat,
                                longitude: stop.stopLon,
                                distanceMeters: dist
                            )
                            transferPoints.append((candidate, dist))
                        }
                    } catch {
                        // Ignore database errors, fallback to same-stop transfer
                    }
                }

                for (transferStop, distance) in transferPoints {
                    let requiredTransferSeconds = distance > 0 ? max(300, Int(distance / 1.2) + 120) : minimumTransferSeconds
                    let boardingAfter = state.legs.isEmpty ? state.arrivalSeconds : state.arrivalSeconds + requiredTransferSeconds

                    // 1. Direct candidates to destination from this transfer point
                    let directCandidates = try await VictorianBusGTFSDatabase.shared.directRoutePlanCandidates(
                        originStopIds: [transferStop.stopId],
                        destinationStopIds: Array(destinationStopIds),
                        afterSeconds: boardingAfter,
                        limit: 4
                    )

                    for candidate in directCandidates where !state.usedTripIds.contains(candidate.tripId) {
                        let transitLeg = try await makeLeg(
                            from: candidate,
                            originOverride: transferStop,
                            destinationOverride: destinationById[candidate.destinationStopId]
                        )
                        
                        let optionLegs: [RoutePlanLeg]
                        if distance > 0 {
                            let walkLeg = makeWalkLeg(
                                from: state.currentStop,
                                to: transferStop,
                                departureSeconds: state.arrivalSeconds,
                                arrivalSeconds: state.arrivalSeconds + Int(distance / 1.2)
                            )
                            optionLegs = state.legs + [walkLeg, transitLeg]
                        } else {
                            optionLegs = state.legs + [transitLeg]
                        }
                        completed.append(makeOption(from: optionLegs))
                    }

                    // 2. Reachable candidates for multi-leg search
                    let transitLegCount = state.legs.filter { $0.routeShortName != "Walk" }.count
                    guard transitLegCount < maximumTransfers else { continue }

                    let reachable = try await VictorianBusGTFSDatabase.shared.reachableRoutePlanLegCandidates(
                        originStopIds: [transferStop.stopId],
                        afterSeconds: boardingAfter,
                        horizonSeconds: legSearchHorizonSeconds,
                        limit: 64
                    )

                    for candidate in reachable {
                        if destinationStopIds.contains(candidate.destinationStopId) {
                            continue
                        }
                        if state.visitedStopIds.contains(candidate.destinationStopId) ||
                            state.usedTripIds.contains(candidate.tripId) {
                            continue
                        }
                        guard candidate.destinationSeconds - nowSeconds <= maximumJourneySeconds else { continue }

                        let leg = try await makeLeg(
                            from: candidate,
                            originOverride: transferStop,
                            destinationOverride: nil
                        )
                        let previousBest = bestArrivalByStop[leg.destinationStop.stopId] ?? Int.max
                        guard leg.arrivalSeconds + 60 < previousBest else { continue }
                        bestArrivalByStop[leg.destinationStop.stopId] = leg.arrivalSeconds

                        let newLegs: [RoutePlanLeg]
                        if distance > 0 {
                            let walkLeg = makeWalkLeg(
                                from: state.currentStop,
                                to: transferStop,
                                departureSeconds: state.arrivalSeconds,
                                arrivalSeconds: state.arrivalSeconds + Int(distance / 1.2)
                            )
                            newLegs = state.legs + [walkLeg, leg]
                        } else {
                            newLegs = state.legs + [leg]
                        }

                        nextStates.append(
                            SearchState(
                                currentStop: leg.destinationStop,
                                arrivalSeconds: leg.arrivalSeconds,
                                legs: newLegs,
                                visitedStopIds: state.visitedStopIds.union([transferStop.stopId, leg.destinationStop.stopId]),
                                usedTripIds: state.usedTripIds.union([leg.tripId])
                            )
                        )
                    }
                }
            }

            frontier = nextStates
                .sorted { lhs, rhs in
                    if lhs.arrivalSeconds != rhs.arrivalSeconds {
                        return lhs.arrivalSeconds < rhs.arrivalSeconds
                    }
                    return lhs.legs.count < rhs.legs.count
                }
                .prefix(maximumStatesPerRound)
                .map { $0 }
        }

        return completed
    }

    private func makeOption(from legs: [RoutePlanLeg]) -> RoutePlanOption {
        RoutePlanOption(
            id: legs.map(\.id).joined(separator: "|"),
            legs: legs
        )
    }

    private func makeWalkLeg(
        from origin: RoutePlanStopCandidate,
        to destination: RoutePlanStopCandidate,
        departureSeconds: Int,
        arrivalSeconds: Int
    ) -> RoutePlanLeg {
        let depTime = secondsToTimeString(departureSeconds)
        let arrTime = secondsToTimeString(arrivalSeconds)
        
        let stops = [
            RoutePlanTripStop(
                stopId: origin.stopId,
                stopName: origin.stopName,
                stopCode: origin.stopCode,
                latitude: origin.latitude,
                longitude: origin.longitude,
                scheduledTime: depTime,
                stopSequence: 1,
                isBoardingStop: true,
                isAlightingStop: false
            ),
            RoutePlanTripStop(
                stopId: destination.stopId,
                stopName: destination.stopName,
                stopCode: destination.stopCode,
                latitude: destination.latitude,
                longitude: destination.longitude,
                scheduledTime: arrTime,
                stopSequence: 2,
                isBoardingStop: false,
                isAlightingStop: true
            )
        ]
        
        return RoutePlanLeg(
            id: "walk:\(origin.stopId):\(destination.stopId):\(departureSeconds)",
            tripId: "walk",
            routeId: "walk",
            routeShortName: "Walk",
            routeLongName: "Walk to next stop",
            headsign: nil,
            originStop: origin,
            destinationStop: destination,
            departureTime: depTime,
            arrivalTime: arrTime,
            departureSeconds: departureSeconds,
            arrivalSeconds: arrivalSeconds,
            stops: stops,
            pathCoordinates: [
                origin.coordinate,
                destination.coordinate
            ]
        )
    }

    private struct SearchState {
        let currentStop: RoutePlanStopCandidate
        let arrivalSeconds: Int
        let legs: [RoutePlanLeg]
        let visitedStopIds: Set<String>
        let usedTripIds: Set<String>
    }

    private func makeLeg(
        from candidate: VictorianBusGTFSDatabase.DirectRoutePlanCandidate,
        originOverride: RoutePlanStopCandidate?,
        destinationOverride: RoutePlanStopCandidate?
    ) async throws -> RoutePlanLeg {
        let originStop = originOverride ?? RoutePlanStopCandidate(
            stopId: candidate.originStopId,
            stopName: candidate.originStopName,
            stopCode: candidate.originStopCode,
            latitude: candidate.originLat,
            longitude: candidate.originLon,
            distanceMeters: 0
        )
        let destinationStop = destinationOverride ?? RoutePlanStopCandidate(
            stopId: candidate.destinationStopId,
            stopName: candidate.destinationStopName,
            stopCode: candidate.destinationStopCode,
            latitude: candidate.destinationLat,
            longitude: candidate.destinationLon,
            distanceMeters: 0
        )

        let pattern = try await VictorianBusGTFSDatabase.shared.routePlanTripStops(
            tripId: candidate.tripId,
            fromSequence: candidate.originSequence,
            toSequence: candidate.destinationSequence
        )
        let stops = pattern.map { stop in
            RoutePlanTripStop(
                stopId: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                latitude: stop.stopLat,
                longitude: stop.stopLon,
                scheduledTime: stop.scheduledTime.map(displayTime),
                stopSequence: stop.stopSequence,
                isBoardingStop: stop.stopSequence == candidate.originSequence,
                isAlightingStop: stop.stopSequence == candidate.destinationSequence
            )
        }
        let shapeCoordinates = try await VictorianBusGTFSDatabase.shared.routePlanShapeCoordinates(
            tripId: candidate.tripId,
            fromSequence: candidate.originSequence,
            toSequence: candidate.destinationSequence
        )
        let pathCoordinates = transitPathCoordinates(
            shapeCoordinates,
            origin: originStop.coordinate,
            destination: destinationStop.coordinate
        )

        let routeLabel = candidate.routeShortName.isEmpty ? candidate.routeId : candidate.routeShortName
        return RoutePlanLeg(
            id: "\(candidate.tripId):\(candidate.originSequence):\(candidate.destinationSequence)",
            tripId: candidate.tripId,
            routeId: candidate.routeId,
            routeShortName: routeLabel,
            routeLongName: candidate.routeLongName,
            headsign: candidate.tripHeadsign,
            originStop: originStop,
            destinationStop: destinationStop,
            departureTime: candidate.originTime.map(displayTime) ?? secondsToTimeString(candidate.originSeconds),
            arrivalTime: candidate.destinationTime.map(displayTime) ?? secondsToTimeString(candidate.destinationSeconds),
            departureSeconds: candidate.originSeconds,
            arrivalSeconds: candidate.destinationSeconds,
            stops: stops,
            pathCoordinates: pathCoordinates
        )
    }

    private func transitPathCoordinates(
        _ shapeCoordinates: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        guard shapeCoordinates.count > 1 else { return [] }

        var coordinates = shapeCoordinates
        if let first = coordinates.first, distance(from: first, to: origin) > 20 {
            coordinates.insert(origin, at: 0)
        }
        if let last = coordinates.last, distance(from: last, to: destination) > 20 {
            coordinates.append(destination)
        }
        return coordinates
    }

    private func distance(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(
            from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        )
    }

    private func enrichWithWalkingDirections(_ options: [RoutePlanOption]) async -> [RoutePlanOption] {
        var uniqueWalkLegs: [String: RoutePlanLeg] = [:]
        for option in options {
            for leg in option.legs where leg.routeShortName == "Walk" {
                let key = "\(leg.originStop.stopId):\(leg.destinationStop.stopId)"
                if uniqueWalkLegs[key] == nil { uniqueWalkLegs[key] = leg }
            }
        }
        guard !uniqueWalkLegs.isEmpty else { return options }

        var enrichedLegs: [String: RoutePlanLeg] = [:]
        await withTaskGroup(of: (String, RoutePlanLeg).self) { group in
            for (key, leg) in uniqueWalkLegs {
                group.addTask { (key, await self.walkingDirectionsLeg(for: leg)) }
            }
            for await (key, enriched) in group {
                enrichedLegs[key] = enriched
            }
        }

        return options.map { option in
            RoutePlanOption(
                id: option.id,
                legs: option.legs.map { leg in
                    guard leg.routeShortName == "Walk" else { return leg }
                    let key = "\(leg.originStop.stopId):\(leg.destinationStop.stopId)"
                    return enrichedLegs[key] ?? leg
                }
            )
        }
    }

    private func walkingDirectionsLeg(for leg: RoutePlanLeg) async -> RoutePlanLeg {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            location: CLLocation(latitude: leg.originStop.latitude, longitude: leg.originStop.longitude),
            address: nil
        )
        request.destination = MKMapItem(
            location: CLLocation(latitude: leg.destinationStop.latitude, longitude: leg.destinationStop.longitude),
            address: nil
        )
        request.transportType = .walking

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first, route.polyline.pointCount > 1 else { return leg }
            let count = route.polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
            return RoutePlanLeg(
                id: leg.id, tripId: leg.tripId, routeId: leg.routeId,
                routeShortName: leg.routeShortName, routeLongName: leg.routeLongName,
                headsign: leg.headsign,
                originStop: leg.originStop, destinationStop: leg.destinationStop,
                departureTime: leg.departureTime, arrivalTime: leg.arrivalTime,
                departureSeconds: leg.departureSeconds, arrivalSeconds: leg.arrivalSeconds,
                stops: leg.stops, pathCoordinates: coords
            )
        } catch {
            return leg
        }
    }

    private func bestOptions(from options: [RoutePlanOption]) -> [RoutePlanOption] {
        var seen: Set<String> = []
        let sorted = options.sorted { lhs, rhs in
            if lhs.durationMinutes != rhs.durationMinutes {
                return lhs.durationMinutes < rhs.durationMinutes
            }
            if lhs.arrivalSeconds != rhs.arrivalSeconds {
                return lhs.arrivalSeconds < rhs.arrivalSeconds
            }
            return lhs.transferCount < rhs.transferCount
        }

        return sorted.compactMap { option in
            let signature = option.legs
                .map { "\($0.tripId):\($0.originStop.stopId):\($0.destinationStop.stopId)" }
                .joined(separator: "|")
            guard !seen.contains(signature) else { return nil }
            seen.insert(signature)
            return option
        }
        .prefix(10)
        .map { $0 }
    }

    private func mapStopCandidates(
        _ candidates: [(stop: GTFSStop, distanceMeters: Double)]
    ) -> [RoutePlanStopCandidate] {
        candidates.map { stop, distance in
            RoutePlanStopCandidate(
                stopId: stop.stopId,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                latitude: stop.stopLat,
                longitude: stop.stopLon,
                distanceMeters: distance
            )
        }
    }

    private func displayTime(_ gtfsTime: String) -> String {
        let parts = gtfsTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return gtfsTime }
        return secondsToTimeString(parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0))
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
