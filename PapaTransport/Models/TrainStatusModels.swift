import Foundation

struct TrainLineDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Victorian train line status, separate from the station departure board.
struct TrainInfo: Identifiable {
    let id = UUID()
    let lineName: String
    let serviceIsGood: Bool
    let serviceStatusMessage: String
    let alerts: [TrainServiceAlert]
    let plannedWorks: [TrainPlannedWork]
    let melbourneTimeAtFetch: String
}

struct TrainServiceAlert: Identifiable {
    let id: String
    let alertType: String
    let plainText: String
    let additionalTravelMinutes: Int?
    let disruptionDueTo: String?
}

struct TrainPlannedWork: Identifiable {
    let id: Int
    let title: String
    let link: String
    let type: String
    let upcomingCurrent: String
    let affectedStations: [String]
}

extension TrainInfo {
    static func placeholder(lineName: String) -> TrainInfo {
        TrainInfo(
            lineName: lineName.isEmpty ? "Your train line" : lineName,
            serviceIsGood: true,
            serviceStatusMessage: lineName.isEmpty
                ? "Set your Victorian train line in Settings."
                : "Live service status will appear here.",
            alerts: [],
            plannedWorks: [],
            melbourneTimeAtFetch: "--:-- --"
        )
    }
}
