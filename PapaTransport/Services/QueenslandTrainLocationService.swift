import CoreLocation
import Foundation

final class QueenslandTrainLocationService {
    static let shared = QueenslandTrainLocationService()

    private init() {}

    enum LocateError: LocalizedError {
        case noCandidates
        case tooFarFromTrainCorridor

        var errorDescription: String? {
            switch self {
            case .noCandidates:
                return "PapaTransport could not find a Queensland train that matches your location, time, and selected line."
            case .tooFarFromTrainCorridor:
                return "You seem to be too far from the selected Queensland train line for a useful estimate."
            }
        }
    }

    func availableRoutes() async throws -> [GTFSDatabase.TrainRoute] {
        try await GTFSDatabase.shared.ensureReady()
        return try await GTFSDatabase.shared.trainRoutes()
    }

    func locate(
        location: CLLocation,
        selectedLineName: String,
        directionOverride: TrainLocateDirectionOverride
    ) async throws -> TrainLocateResult {
        try await GTFSDatabase.shared.ensureReady()

        let nowSeconds = GTFSDatabase.brisbaneMidnightSeconds()
        let routeShortName = normalizedLineName(selectedLineName)
        let candidates = try await GTFSDatabase.shared.activeTrainTripCandidates(
            routeShortName: routeShortName,
            directionId: directionOverride.directionId,
            aroundSeconds: nowSeconds
        )

        guard !candidates.isEmpty else {
            throw LocateError.noCandidates
        }

        async let realtimeTask = QueenslandTrainRealtimeService.shared.fetchTripUpdates()
        let tripUpdates = await realtimeTask
        let scored = try await scoreCandidates(
            candidates,
            location: location,
            nowSeconds: nowSeconds,
            tripUpdates: tripUpdates
        )

        guard let best = scored.first else {
            throw LocateError.noCandidates
        }

        guard best.segmentDistanceMeters <= 1_800 || best.score >= 35 else {
            throw LocateError.tooFarFromTrainCorridor
        }

        let confidence = TrainLocateConfidence.from(score: best.score)
        let summaries = scored.prefix(4).map {
            TrainLocateCandidateSummary(
                tripId: $0.candidate.tripId,
                lineName: $0.candidate.routeShortName,
                headsign: $0.candidate.tripHeadsign ?? $0.terminal.stopName,
                directionText: directionText(for: $0.candidate.directionId, terminal: $0.terminal.stopName),
                score: $0.score,
                distanceMeters: Int($0.segmentDistanceMeters.rounded())
            )
        }

        let warning = warningMessage(
            for: best,
            confidence: confidence,
            hasSelectedLine: routeShortName != nil,
            secondBest: scored.dropFirst().first
        )

        return TrainLocateResult(
            lineName: best.candidate.routeShortName,
            directionText: directionText(for: best.candidate.directionId, terminal: best.terminal.stopName),
            headsign: best.candidate.tripHeadsign ?? best.terminal.stopName,
            previousStationName: best.isAtStation ? previousStationName(for: best) : best.previous?.stopName,
            currentStationName: best.isAtStation ? best.currentStation?.stopName : nil,
            nextStationName: best.next?.stopName,
            terminalStationName: best.terminal.stopName,
            minutesToNextStation: best.minutesToNext,
            nextStationScheduledTime: best.nextScheduledTime,
            nextStationPredictedTime: best.nextPredictedTime,
            confidence: confidence,
            confidenceScore: best.score,
            distanceFromTrackMeters: Int(best.segmentDistanceMeters.rounded()),
            accuracyMeters: Int(max(0, location.horizontalAccuracy).rounded()),
            lastUpdated: Date(),
            warningMessage: warning,
            candidateSummaries: summaries
        )
    }

    private func scoreCandidates(
        _ candidates: [GTFSDatabase.ActiveTrainTripCandidate],
        location: CLLocation,
        nowSeconds: Int,
        tripUpdates: [String: GTFSRTTripUpdate]
    ) async throws -> [QueenslandScoredTrainTrip] {
        var results: [QueenslandScoredTrainTrip] = []

        for candidate in candidates {
            let pattern = try await GTFSDatabase.shared.trainTripPattern(tripId: candidate.tripId)
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
        _ candidate: GTFSDatabase.ActiveTrainTripCandidate,
        pattern: [GTFSDatabase.TripPatternStop],
        location: CLLocation,
        nowSeconds: Int,
        delaySeconds: Int
    ) -> QueenslandScoredTrainTrip? {
        let nearestStation = pattern.enumerated()
            .map { index, stop in
                (
                    index: index,
                    stop: stop,
                    distance: CLLocation(latitude: stop.stopLat, longitude: stop.stopLon).distance(from: location)
                )
            }
            .min { $0.distance < $1.distance }

        let stationThreshold = max(160.0, min(300.0, location.horizontalAccuracy * 1.6))
        if let nearestStation, nearestStation.distance <= stationThreshold {
            let previous = nearestStation.index > 0 ? pattern[nearestStation.index - 1] : nil
            let next = nearestStation.index < pattern.count - 1 ? pattern[nearestStation.index + 1] : nil
            let nextSeconds = next.flatMap { scheduledSeconds(for: $0) }.map { $0 + delaySeconds }
            let timePenalty = timePenaltySeconds(
                nowSeconds: nowSeconds,
                lowerBound: scheduledSeconds(for: nearestStation.stop).map { $0 + delaySeconds - 180 },
                upperBound: scheduledSeconds(for: nearestStation.stop).map { $0 + delaySeconds + 240 }
            )
            let score = boundedScore(
                92
                    - nearestStation.distance / 9
                    - Double(timePenalty) / 90
                    - accuracyPenalty(location.horizontalAccuracy)
            )

            return QueenslandScoredTrainTrip(
                candidate: candidate,
                previous: previous,
                currentStation: nearestStation.stop,
                next: next,
                terminal: pattern.last!,
                isAtStation: true,
                score: score,
                segmentDistanceMeters: nearestStation.distance,
                minutesToNext: minutesUntil(nextSeconds, nowSeconds: nowSeconds),
                nextScheduledTime: nextSeconds.map { secondsToTimeString($0 - delaySeconds) },
                nextPredictedTime: delaySeconds == 0 ? nil : nextSeconds.map(secondsToTimeString)
            )
        }

        var bestSegment: QueenslandSegmentScore?
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
                    - projected.distanceMeters / 18
                    - Double(timePenalty) / 55
                    - coursePenalty
                    - progressPenalty
                    - accuracyPenalty(location.horizontalAccuracy)
            )

            let segment = QueenslandSegmentScore(
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

        return QueenslandScoredTrainTrip(
            candidate: candidate,
            previous: bestSegment.previous,
            currentStation: nil,
            next: bestSegment.next,
            terminal: pattern.last!,
            isAtStation: false,
            score: bestSegment.score,
            segmentDistanceMeters: bestSegment.distanceMeters,
            minutesToNext: minutesUntil(bestSegment.nextSeconds, nowSeconds: nowSeconds),
            nextScheduledTime: secondsToTimeString(bestSegment.nextSeconds - delaySeconds),
            nextPredictedTime: delaySeconds == 0 ? nil : secondsToTimeString(bestSegment.nextSeconds)
        )
    }

    private func warningMessage(
        for best: QueenslandScoredTrainTrip,
        confidence: TrainLocateConfidence,
        hasSelectedLine: Bool,
        secondBest: QueenslandScoredTrainTrip?
    ) -> String? {
        if !hasSelectedLine {
            return "No line is selected, so this estimate is comparing several possible Queensland trains."
        }

        if let secondBest, best.score - secondBest.score < 8 {
            return "A few trains look possible here. Choosing your line or direction can make this clearer."
        }

        if confidence == .low {
            return "This estimate is uncertain because location quality, shared tracks, or timing may be affecting the match."
        }

        if best.segmentDistanceMeters > 800 {
            return "You do not seem very close to the selected Queensland train line."
        }

        return nil
    }

    private func previousStationName(for trip: QueenslandScoredTrainTrip) -> String? {
        guard let previous = trip.previous else { return nil }
        return previous.stopName
    }

    private func normalizedLineName(_ lineName: String) -> String? {
        var trimmed = lineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.localizedCaseInsensitiveContains("your train line") {
            return nil
        }

        if trimmed.lowercased().hasSuffix(" line") {
            trimmed = String(trimmed.dropLast(5))
        }

        return trimmed.isEmpty ? nil : trimmed
    }

    private func directionText(for directionId: Int, terminal: String) -> String {
        if !terminal.isEmpty {
            return "towards \(terminal)"
        }
        return "direction \(directionId + 1)"
    }

    private func scheduledSeconds(for stop: GTFSDatabase.TripPatternStop) -> Int? {
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
        return min(18, max(0, (accuracy - 80) / 18))
    }

    private func coursePenalty(
        location: CLLocation,
        from: GTFSDatabase.TripPatternStop,
        to: GTFSDatabase.TripPatternStop
    ) -> Double {
        guard location.course >= 0, location.speed >= 2 else { return 0 }

        let expected = bearingDegrees(
            fromLatitude: from.stopLat,
            longitude: from.stopLon,
            toLatitude: to.stopLat,
            longitude: to.stopLon
        )
        let difference = angularDifference(location.course, expected)
        return min(30, difference / 5)
    }

    private func project(
        location: CLLocation,
        from: GTFSDatabase.TripPatternStop,
        to: GTFSDatabase.TripPatternStop
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
}

private struct QueenslandScoredTrainTrip {
    let candidate: GTFSDatabase.ActiveTrainTripCandidate
    let previous: GTFSDatabase.TripPatternStop?
    let currentStation: GTFSDatabase.TripPatternStop?
    let next: GTFSDatabase.TripPatternStop?
    let terminal: GTFSDatabase.TripPatternStop
    let isAtStation: Bool
    let score: Double
    let segmentDistanceMeters: Double
    let minutesToNext: Int?
    let nextScheduledTime: String?
    let nextPredictedTime: String?
}

private struct QueenslandSegmentScore {
    let index: Int
    let previous: GTFSDatabase.TripPatternStop
    let next: GTFSDatabase.TripPatternStop
    let distanceMeters: Double
    let score: Double
    let nextSeconds: Int
}
