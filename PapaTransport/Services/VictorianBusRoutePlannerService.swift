import CoreLocation
import Foundation

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

        return RoutePlanResult(
            originCandidates: originStops,
            destinationCandidates: destinationStops,
            options: bestOptions(from: options),
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
                let boardingAfter = state.legs.isEmpty ? state.arrivalSeconds : state.arrivalSeconds + minimumTransferSeconds
                let directCandidates = try await VictorianBusGTFSDatabase.shared.directRoutePlanCandidates(
                    originStopIds: [state.currentStop.stopId],
                    destinationStopIds: Array(destinationStopIds),
                    afterSeconds: boardingAfter,
                    limit: 4
                )

                for candidate in directCandidates where !state.usedTripIds.contains(candidate.tripId) {
                    let leg = try await makeLeg(
                        from: candidate,
                        originOverride: state.currentStop,
                        destinationOverride: destinationById[candidate.destinationStopId]
                    )
                    completed.append(makeOption(from: state.legs + [leg]))
                }

                guard state.legs.count < maximumTransfers else { continue }

                let reachable = try await VictorianBusGTFSDatabase.shared.reachableRoutePlanLegCandidates(
                    originStopIds: [state.currentStop.stopId],
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
                        originOverride: state.currentStop,
                        destinationOverride: nil
                    )
                    let previousBest = bestArrivalByStop[leg.destinationStop.stopId] ?? Int.max
                    guard leg.arrivalSeconds + 60 < previousBest else { continue }
                    bestArrivalByStop[leg.destinationStop.stopId] = leg.arrivalSeconds

                    nextStates.append(
                        SearchState(
                            currentStop: leg.destinationStop,
                            arrivalSeconds: leg.arrivalSeconds,
                            legs: state.legs + [leg],
                            visitedStopIds: state.visitedStopIds.union([leg.destinationStop.stopId]),
                            usedTripIds: state.usedTripIds.union([leg.tripId])
                        )
                    )
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
            stops: stops
        )
    }

    private func bestOptions(from options: [RoutePlanOption]) -> [RoutePlanOption] {
        var seen: Set<String> = []
        let sorted = options.sorted { lhs, rhs in
            if lhs.arrivalSeconds != rhs.arrivalSeconds {
                return lhs.arrivalSeconds < rhs.arrivalSeconds
            }
            if lhs.transferCount != rhs.transferCount {
                return lhs.transferCount < rhs.transferCount
            }
            return lhs.durationMinutes < rhs.durationMinutes
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
