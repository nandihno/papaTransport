import CoreLocation
import Foundation

struct RoutePlanStopCandidate: Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double

    var id: String { stopId }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RoutePlanTripStop: Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double
    let scheduledTime: String?
    let stopSequence: Int
    let isBoardingStop: Bool
    let isAlightingStop: Bool

    var id: String { "\(stopId):\(stopSequence)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RoutePlanLeg: Identifiable {
    let id: String
    let tripId: String
    let routeId: String
    let routeShortName: String
    let routeLongName: String
    let headsign: String?
    let originStop: RoutePlanStopCandidate
    let destinationStop: RoutePlanStopCandidate
    let departureTime: String
    let arrivalTime: String
    let departureSeconds: Int
    let arrivalSeconds: Int
    let stops: [RoutePlanTripStop]
    let pathCoordinates: [CLLocationCoordinate2D]

    var polylineCoordinates: [CLLocationCoordinate2D] {
        pathCoordinates.count > 1 ? pathCoordinates : stops.map(\.coordinate)
    }

    var displayHeadsign: String {
        let trimmed = headsign?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? routeLongName : trimmed
    }

    var durationMinutes: Int {
        max(0, Int(ceil(Double(arrivalSeconds - departureSeconds) / 60.0)))
    }
}

struct RoutePlanOption: Identifiable {
    let id: String
    let legs: [RoutePlanLeg]

    var tripId: String { legs.first?.tripId ?? id }
    var routeId: String { legs.first?.routeId ?? "" }
    var routeShortName: String { legs.first?.routeShortName ?? "" }
    var routeLongName: String { legs.first?.routeLongName ?? "" }
    var headsign: String? { legs.first?.headsign }
    var originStop: RoutePlanStopCandidate? { legs.first?.originStop }
    var destinationStop: RoutePlanStopCandidate? { legs.last?.destinationStop }
    var departureTime: String { legs.first?.departureTime ?? "" }
    var arrivalTime: String { legs.last?.arrivalTime ?? "" }
    var departureSeconds: Int { legs.first?.departureSeconds ?? 0 }
    var arrivalSeconds: Int { legs.last?.arrivalSeconds ?? 0 }
    var stops: [RoutePlanTripStop] { legs.flatMap(\.stops) }

    var durationMinutes: Int {
        guard let first = legs.first, let last = legs.last else { return 0 }
        return max(0, Int(ceil(Double(last.arrivalSeconds - first.departureSeconds) / 60.0)))
    }

    var transferCount: Int {
        max(0, legs.filter { $0.routeShortName != "Walk" }.count - 1)
    }

    var polylineCoordinates: [CLLocationCoordinate2D] {
        legs.flatMap(\.polylineCoordinates)
    }

    var displayHeadsign: String {
        legs.first?.displayHeadsign ?? ""
    }

    var routeSummary: String {
        legs.map(\.routeShortName).joined(separator: " → ")
    }

    var transferSummary: String? {
        let transitLegs = legs.filter { $0.routeShortName != "Walk" }
        guard transitLegs.count > 1 else { return nil }
        
        var totalWait = 0
        for i in 0..<(transitLegs.count - 1) {
            let arrival = transitLegs[i].arrivalSeconds
            let nextDeparture = transitLegs[i+1].departureSeconds
            totalWait += max(0, (nextDeparture - arrival) / 60)
        }
        
        let firstTransferStop = transitLegs[0].destinationStop.stopName
        let tCount = transitLegs.count - 1
        if tCount == 1 {
            return "Transfer at \(firstTransferStop) · \(totalWait) min total layover"
        }
        return "\(tCount) transfers · first at \(firstTransferStop) · \(totalWait) min total layover"
    }
}

struct RoutePlanResult {
    let originCandidates: [RoutePlanStopCandidate]
    let destinationCandidates: [RoutePlanStopCandidate]
    let options: [RoutePlanOption]
    let generatedAt: Date

    var selectedOrigin: RoutePlanStopCandidate? { originCandidates.first }
    var selectedDestination: RoutePlanStopCandidate? { destinationCandidates.first }
}
