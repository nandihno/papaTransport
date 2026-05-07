import CoreLocation
import Foundation

final class VictorianBusLocatorService {
    static let shared = VictorianBusLocatorService()

    private init() {}

    enum LocateError: LocalizedError {
        case noCandidates
        case tooFarFromBusRoute

        var errorDescription: String? {
            switch self {
            case .noCandidates:
                return "PapaTransport could not find a bus that matches your location, time, and selected route."
            case .tooFarFromBusRoute:
                return "You seem to be too far from the selected bus route for a useful estimate."
            }
        }
    }

    /// Returns nearby bus stops along with the bus routes that serve each stop today.
    /// Stops with zero active routes today are filtered out so the picker only shows
    /// useful options.
    func nearbyStopsWithRoutes(
        location: CLLocation,
        radiusMeters: Double = 300
    ) async throws -> [BusLocateNearbyStop] {
        try await VictorianBusGTFSDatabase.shared.ensureReady()

        let stops = try await VictorianBusGTFSDatabase.shared.nearbyBusStops(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radiusMeters: radiusMeters
        )

        var results: [BusLocateNearbyStop] = []
        for (stop, distance) in stops {
            let routes = try await VictorianBusGTFSDatabase.shared.routesAtStopToday(stopId: stop.stopId)
            guard !routes.isEmpty else { continue }

            let mapped = routes.map { route in
                BusLocateRouteAtStop(
                    routeId: route.routeId,
                    routeShortName: route.routeShortName,
                    routeLongName: route.routeLongName,
                    directionId: route.directionId,
                    headsign: route.tripHeadsign
                )
            }

            results.append(
                BusLocateNearbyStop(
                    stopId: stop.stopId,
                    stopName: stop.stopName,
                    stopCode: stop.stopCode,
                    latitude: stop.stopLat,
                    longitude: stop.stopLon,
                    distanceMeters: distance,
                    routes: mapped
                )
            )
        }

        return results
    }

    /// Locates the bus the user has chosen. Returns the result and an updated session
    /// containing the locked tripId (so subsequent calls keep tracking the same trip
    /// unless a clearly-better candidate appears).
    func locate(
        location: CLLocation,
        session: BusLocateSession
    ) async throws -> (result: BusLocateResult, session: BusLocateSession) {
        try await VictorianBusGTFSDatabase.shared.ensureReady()

        let nowSeconds = Self.melbourneMidnightSeconds()
        let candidates = try await VictorianBusGTFSDatabase.shared.activeTripsThroughStop(
            routeId: session.routeId,
            directionId: session.directionId,
            stopId: session.boardingStopId,
            aroundSeconds: nowSeconds
        )

        guard !candidates.isEmpty else {
            throw LocateError.noCandidates
        }

        async let realtimeTask = VictorianBusLocatorRealtimeService.shared.fetchTripUpdates()
        let tripUpdates = await realtimeTask

        let scored = try await scoreCandidates(
            candidates,
            location: location,
            nowSeconds: nowSeconds,
            tripUpdates: tripUpdates
        )

        guard let initialBest = scored.first else {
            throw LocateError.noCandidates
        }

        // Anti-flicker trip lock: if a tripId was already locked, prefer it unless
        // an alternate beats it by 12+ points. Buses bunch and a slightly-better
        // alternate is usually the next bus, not a better match for the same trip.
        let chosen: ScoredTrip
        if let lockedTripId = session.lockedTripId,
           let lockedScored = scored.first(where: { $0.candidate.tripId == lockedTripId }) {
            if initialBest.candidate.tripId != lockedTripId,
               initialBest.score - lockedScored.score >= 12 {
                chosen = initialBest
            } else {
                chosen = lockedScored
            }
        } else {
            chosen = initialBest
        }

        guard chosen.segmentDistanceMeters <= 250 || chosen.score >= 50 else {
            throw LocateError.tooFarFromBusRoute
        }

        let confidence = BusLocateConfidence.from(score: chosen.score)
        let warning = warningMessage(for: chosen, confidence: confidence)

        // Lock onto the chosen trip once we are at least medium confident.
        let updatedSession: BusLocateSession
        if confidence == .low {
            updatedSession = session
        } else {
            updatedSession = session.locking(tripId: chosen.candidate.tripId)
        }

        let result = BusLocateResult(
            routeShortName: chosen.candidate.routeShortName,
            routeLongName: chosen.candidate.routeLongName,
            headsign: chosen.candidate.tripHeadsign ?? chosen.terminal.stopName,
            boardingStopName: session.boardingStopName,
            previousStopName: chosen.isAtStop ? previousStopName(for: chosen) : chosen.previous?.stopName,
            currentStopName: chosen.isAtStop ? chosen.currentStop?.stopName : nil,
            nextStopName: chosen.next?.stopName,
            terminalStopName: chosen.terminal.stopName,
            minutesToNextStop: chosen.minutesToNext,
            nextStopScheduledTime: chosen.nextScheduledTime,
            nextStopPredictedTime: chosen.nextPredictedTime,
            confidence: confidence,
            confidenceScore: chosen.score,
            distanceFromRouteMeters: Int(chosen.segmentDistanceMeters.rounded()),
            accuracyMeters: Int(max(0, location.horizontalAccuracy).rounded()),
            tripId: chosen.candidate.tripId,
            lastUpdated: Date(),
            warningMessage: warning
        )

        return (result, updatedSession)
    }

    // MARK: - Scoring

    private func scoreCandidates(
        _ candidates: [VictorianBusGTFSDatabase.ActiveTripCandidate],
        location: CLLocation,
        nowSeconds: Int,
        tripUpdates: [String: GTFSRTTripUpdate]
    ) async throws -> [ScoredTrip] {
        var results: [ScoredTrip] = []

        for candidate in candidates {
            let pattern = try await VictorianBusGTFSDatabase.shared.tripPattern(tripId: candidate.tripId)
            guard pattern.count >= 2 else { continue }
            let delaySeconds = Int(tripUpdates[candidate.tripId]?.delay ?? 0)

            if let scored = scoreCandidate(
                candidate,
                pattern: pattern,
                location: location,
                nowSeconds: nowSeconds,
                delaySeconds: delaySeconds
            ) {
                results.append(scored)
            }
        }

        return results.sorted {
            if abs($0.score - $1.score) > 0.1 {
                return $0.score > $1.score
            }
            return $0.segmentDistanceMeters < $1.segmentDistanceMeters
        }
    }

    private func scoreCandidate(
        _ candidate: VictorianBusGTFSDatabase.ActiveTripCandidate,
        pattern: [VictorianBusGTFSDatabase.TripPatternStop],
        location: CLLocation,
        nowSeconds: Int,
        delaySeconds: Int
    ) -> ScoredTrip? {
        let nearestStop = pattern.enumerated()
            .map { index, stop in
                (
                    index: index,
                    stop: stop,
                    distance: CLLocation(latitude: stop.stopLat, longitude: stop.stopLon).distance(from: location)
                )
            }
            .min { $0.distance < $1.distance }

        // Bus stops are kerb-side and small; threshold is much tighter than trains.
        let stopThreshold = max(40.0, min(75.0, location.horizontalAccuracy * 0.9))
        if let nearestStop, nearestStop.distance <= stopThreshold {
            let previous = nearestStop.index > 0 ? pattern[nearestStop.index - 1] : nil
            let next = nearestStop.index < pattern.count - 1 ? pattern[nearestStop.index + 1] : nil
            let nextSeconds = next.flatMap { scheduledSeconds(for: $0) }.map { $0 + delaySeconds }
            let timePenalty = timePenaltySeconds(
                nowSeconds: nowSeconds,
                lowerBound: scheduledSeconds(for: nearestStop.stop).map { $0 + delaySeconds - 180 },
                upperBound: scheduledSeconds(for: nearestStop.stop).map { $0 + delaySeconds + 240 }
            )
            let score = boundedScore(
                94
                    - nearestStop.distance / 4
                    - Double(timePenalty) / 90
                    - accuracyPenalty(location.horizontalAccuracy)
            )

            return ScoredTrip(
                candidate: candidate,
                previous: previous,
                currentStop: nearestStop.stop,
                next: next,
                terminal: pattern.last!,
                isAtStop: true,
                score: score,
                segmentDistanceMeters: nearestStop.distance,
                minutesToNext: minutesUntil(nextSeconds, nowSeconds: nowSeconds),
                nextScheduledTime: nextSeconds.map { secondsToTimeString($0 - delaySeconds) },
                nextPredictedTime: delaySeconds == 0 ? nil : nextSeconds.map(secondsToTimeString)
            )
        }

        var bestSegment: SegmentScore?
        for index in 0..<(pattern.count - 1) {
            let previous = pattern[index]
            let next = pattern[index + 1]
            guard let previousSeconds = scheduledSeconds(for: previous),
                  let nextSeconds = scheduledSeconds(for: next) else {
                continue
            }

            let projected = project(
                location: location,
                from: previous,
                to: next
            )
            let effectivePrevious = previousSeconds + delaySeconds
            let effectiveNext = nextSeconds + delaySeconds
            let timePenalty = timePenaltySeconds(
                nowSeconds: nowSeconds,
                lowerBound: effectivePrevious - 240,
                upperBound: effectiveNext + 240
            )
            let coursePenalty = coursePenalty(location: location, from: previous, to: next)
            let progressPenalty = projected.progress < -0.18 || projected.progress > 1.18 ? 8.0 : 0.0
            let score = boundedScore(
                100
                    - projected.distanceMeters / 6
                    - Double(timePenalty) / 55
                    - coursePenalty
                    - progressPenalty
                    - accuracyPenalty(location.horizontalAccuracy)
            )

            let segment = SegmentScore(
                index: index,
                previous: previous,
                next: next,
                distanceMeters: projected.distanceMeters,
                score: score,
                nextSeconds: effectiveNext
            )

            if bestSegment == nil || segment.score > bestSegment!.score {
                bestSegment = segment
            }
        }

        guard let bestSegment else { return nil }

        return ScoredTrip(
            candidate: candidate,
            previous: bestSegment.previous,
            currentStop: nil,
            next: bestSegment.next,
            terminal: pattern.last!,
            isAtStop: false,
            score: bestSegment.score,
            segmentDistanceMeters: bestSegment.distanceMeters,
            minutesToNext: minutesUntil(bestSegment.nextSeconds, nowSeconds: nowSeconds),
            nextScheduledTime: secondsToTimeString(bestSegment.nextSeconds - delaySeconds),
            nextPredictedTime: delaySeconds == 0 ? nil : secondsToTimeString(bestSegment.nextSeconds)
        )
    }

    private func warningMessage(
        for best: ScoredTrip,
        confidence: BusLocateConfidence
    ) -> String? {
        if confidence == .low {
            return "This estimate is uncertain because location quality, traffic, or timing may be affecting the match."
        }

        if best.segmentDistanceMeters > 200 {
            return "You do not seem very close to the selected bus route. If you have changed buses, pick a new stop."
        }

        return nil
    }

    private func previousStopName(for trip: ScoredTrip) -> String? {
        guard let previous = trip.previous else { return nil }
        return previous.stopName
    }

    private func scheduledSeconds(for stop: VictorianBusGTFSDatabase.TripPatternStop) -> Int? {
        if stop.departureSeconds > 0 { return stop.departureSeconds }
        if stop.arrivalSeconds > 0 { return stop.arrivalSeconds }
        return nil
    }

    private func timePenaltySeconds(nowSeconds: Int, lowerBound: Int?, upperBound: Int?) -> Int {
        guard let lowerBound, let upperBound else { return 0 }
        if nowSeconds < lowerBound { return lowerBound - nowSeconds }
        if nowSeconds > upperBound { return nowSeconds - upperBound }
        return 0
    }

    private func minutesUntil(_ seconds: Int?, nowSeconds: Int) -> Int? {
        guard let seconds else { return nil }
        return max(0, Int(ceil(Double(seconds - nowSeconds) / 60.0)))
    }

    private func accuracyPenalty(_ accuracy: CLLocationAccuracy) -> Double {
        guard accuracy > 0 else { return 10 }
        return min(18, max(0, (accuracy - 30) / 10))
    }

    private func coursePenalty(
        location: CLLocation,
        from: VictorianBusGTFSDatabase.TripPatternStop,
        to: VictorianBusGTFSDatabase.TripPatternStop
    ) -> Double {
        // Buses creep in traffic; only weight bearing when actually moving.
        guard location.course >= 0, location.speed >= 5 else { return 0 }

        let expected = bearingDegrees(
            fromLatitude: from.stopLat,
            longitude: from.stopLon,
            toLatitude: to.stopLat,
            longitude: to.stopLon
        )
        let difference = angularDifference(location.course, expected)
        return min(20, difference / 6)
    }

    private func project(
        location: CLLocation,
        from: VictorianBusGTFSDatabase.TripPatternStop,
        to: VictorianBusGTFSDatabase.TripPatternStop
    ) -> (distanceMeters: Double, progress: Double) {
        let referenceLatitude = location.coordinate.latitude * .pi / 180
        let radius = 6_371_000.0

        func point(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
            let lat = latitude * .pi / 180
            let lon = longitude * .pi / 180
            return (
                x: radius * lon * cos(referenceLatitude),
                y: radius * lat
            )
        }

        let user = point(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let start = point(latitude: from.stopLat, longitude: from.stopLon)
        let end = point(latitude: to.stopLat, longitude: to.stopLon)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            let distance = hypot(user.x - start.x, user.y - start.y)
            return (distance, 0)
        }

        let rawProgress = ((user.x - start.x) * dx + (user.y - start.y) * dy) / lengthSquared
        let clamped = min(1, max(0, rawProgress))
        let projected = (x: start.x + clamped * dx, y: start.y + clamped * dy)
        let distance = hypot(user.x - projected.x, user.y - projected.y)

        return (distance, rawProgress)
    }

    private func bearingDegrees(
        fromLatitude: Double,
        longitude fromLongitude: Double,
        toLatitude: Double,
        longitude toLongitude: Double
    ) -> Double {
        let lat1 = fromLatitude * .pi / 180
        let lat2 = toLatitude * .pi / 180
        let deltaLon = (toLongitude - fromLongitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    private func boundedScore(_ score: Double) -> Double {
        min(100, max(0, score))
    }

    private func secondsToTimeString(_ totalSeconds: Int) -> String {
        let safeSeconds = max(0, totalSeconds)
        let hours = (safeSeconds / 3600) % 24
        let minutes = (safeSeconds % 3600) / 60
        let ampm = hours >= 12 ? "PM" : "AM"
        let displayHour = hours == 0 ? 12 : (hours > 12 ? hours - 12 : hours)
        return String(format: "%d:%02d %@", displayHour, minutes, ampm)
    }

    static func melbourneMidnightSeconds() -> Int {
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourne
        let now = Date()
        return calendar.component(.hour, from: now) * 3600
            + calendar.component(.minute, from: now) * 60
            + calendar.component(.second, from: now)
    }
}

private struct ScoredTrip {
    let candidate: VictorianBusGTFSDatabase.ActiveTripCandidate
    let previous: VictorianBusGTFSDatabase.TripPatternStop?
    let currentStop: VictorianBusGTFSDatabase.TripPatternStop?
    let next: VictorianBusGTFSDatabase.TripPatternStop?
    let terminal: VictorianBusGTFSDatabase.TripPatternStop
    let isAtStop: Bool
    let score: Double
    let segmentDistanceMeters: Double
    let minutesToNext: Int?
    let nextScheduledTime: String?
    let nextPredictedTime: String?
}

private struct SegmentScore {
    let index: Int
    let previous: VictorianBusGTFSDatabase.TripPatternStop
    let next: VictorianBusGTFSDatabase.TripPatternStop
    let distanceMeters: Double
    let score: Double
    let nextSeconds: Int
}
