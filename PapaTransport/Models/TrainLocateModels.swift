import CoreLocation
import Foundation

enum TrainLocateDirectionOverride: String, CaseIterable, Identifiable {
    case automatic
    case outbound
    case inbound

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto"
        case .outbound:
            return "Away"
        case .inbound:
            return "City"
        }
    }

    var directionId: Int? {
        switch self {
        case .automatic:
            return nil
        case .outbound:
            return 0
        case .inbound:
            return 1
        }
    }
}

enum TrainLocateConfidence: String {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    static func from(score: Double) -> TrainLocateConfidence {
        if score >= 75 { return .high }
        if score >= 55 { return .medium }
        return .low
    }
}

struct TrainLocateResult: Identifiable {
    let id = UUID()
    let lineName: String
    let directionText: String
    let headsign: String
    let previousStationName: String?
    let currentStationName: String?
    let nextStationName: String?
    let terminalStationName: String
    let minutesToNextStation: Int?
    let nextStationScheduledTime: String?
    let nextStationPredictedTime: String?
    let confidence: TrainLocateConfidence
    let confidenceScore: Double
    let distanceFromTrackMeters: Int
    let accuracyMeters: Int
    let lastUpdated: Date
    let warningMessage: String?
    let candidateSummaries: [TrainLocateCandidateSummary]

    var isAtStation: Bool {
        currentStationName != nil
    }

    var primaryMessage: String {
        if let currentStationName {
            return "You appear to be at \(currentStationName)"
        }

        if let previousStationName {
            return "You appear to have just left \(previousStationName)"
        }

        return "Your train position was estimated"
    }

    var nextStationMessage: String {
        guard let nextStationName else { return "This appears to be the final stop" }
        return "Your next station should be \(nextStationName)"
    }
}

struct TrainLocateCandidateSummary: Identifiable {
    let tripId: String
    let lineName: String
    let headsign: String
    let directionText: String
    let score: Double
    let distanceMeters: Int

    var id: String { tripId }
}
