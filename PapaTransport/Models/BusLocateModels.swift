import CoreLocation
import Foundation

enum BusLocateConfidence: String {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    static func from(score: Double) -> BusLocateConfidence {
        if score >= 75 { return .high }
        if score >= 55 { return .medium }
        return .low
    }
}

struct BusLocateNearbyStop: Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double
    let routes: [BusLocateRouteAtStop]

    var id: String { stopId }
}

struct BusLocateRouteAtStop: Identifiable, Hashable {
    let routeId: String
    let routeShortName: String
    let routeLongName: String
    let directionId: Int
    let headsign: String?

    var id: String { "\(routeId)-\(directionId)" }

    var displayHeadsign: String {
        let trimmed = headsign?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? routeLongName : trimmed
    }
}

struct BusLocateSession: Equatable {
    let boardingStopId: String
    let boardingStopName: String
    let routeId: String
    let routeShortName: String
    let directionId: Int
    let headsign: String?
    var lockedTripId: String?

    func locking(tripId: String) -> BusLocateSession {
        var copy = self
        copy.lockedTripId = tripId
        return copy
    }
}

struct BusLocateResult: Identifiable {
    let id = UUID()
    let routeShortName: String
    let routeLongName: String
    let headsign: String
    let boardingStopName: String
    let previousStopName: String?
    let currentStopName: String?
    let nextStopName: String?
    let terminalStopName: String
    let minutesToNextStop: Int?
    let nextStopScheduledTime: String?
    let nextStopPredictedTime: String?
    let confidence: BusLocateConfidence
    let confidenceScore: Double
    let distanceFromRouteMeters: Int
    let accuracyMeters: Int
    let tripId: String
    let lastUpdated: Date
    let warningMessage: String?

    var isAtStop: Bool {
        currentStopName != nil
    }

    var primaryMessage: String {
        if let currentStopName {
            return "You appear to be at \(currentStopName)"
        }

        if let previousStopName {
            return "You appear to have just left \(previousStopName)"
        }

        return "Your bus position was estimated"
    }

    var nextStopMessage: String {
        guard let nextStopName else { return "This appears to be the final stop" }
        return "Your next stop should be \(nextStopName)"
    }
}
