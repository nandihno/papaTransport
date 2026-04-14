import Foundation

struct TrainInfo: Identifiable {
    let id = UUID()
    let lineName: String
    let serviceIsGood: Bool
    let serviceStatusMessage: String
    let alerts: [TrainServiceAlert]
    let plannedWorks: [TrainPlannedWork]
    let homeStationName: String
    let cityStationName: String
    let homeStationDepartures: [TrainDeparture]
    let homeStationAllDepartures: [TrainDeparture]
    let cityStationDepartures: [TrainDeparture]
    let cityStationAllDepartures: [TrainDeparture]
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

struct TrainDeparture: Identifiable {
    let id = UUID()
    let station: String
    let isToCity: Bool
    let scheduledTimeStr: String
    let estimatedArrivalStr: String
    let estimatedDepartureStr: String
    let estimatedDepartureSeconds: Int
    let platform: String
    let estimatedPlatform: String
}

struct CommutingSnapshot {
    let trainInfo: TrainInfo?
    let busInfo: BusInfo?
    let fetchedAt: Date
}

extension TrainInfo {
    static func placeholder(
        lineName: String,
        homeStation: String,
        cityStation: String
    ) -> TrainInfo {
        let now = TrainService.secondsSinceMidnight()
        let resolvedLineName = lineName.isEmpty ? "Your train line" : lineName
        let resolvedHomeStation = homeStation.isEmpty ? "Home station" : homeStation
        let resolvedCityStation = cityStation.isEmpty ? "City station" : cityStation

        func departures(startingAt base: Int) -> [TrainDeparture] {
            (0..<4).map { index in
                let time = TrainService.secondsToTimeString(base + index * 600)
                return TrainDeparture(
                    station: "",
                    isToCity: true,
                    scheduledTimeStr: time,
                    estimatedArrivalStr: time,
                    estimatedDepartureStr: time,
                    estimatedDepartureSeconds: base + index * 600,
                    platform: "1",
                    estimatedPlatform: "1"
                )
            }
        }

        return TrainInfo(
            lineName: resolvedLineName,
            serviceIsGood: true,
            serviceStatusMessage: lineName.isEmpty
                ? "Set your Victorian train line in Settings."
                : "Live service status will appear here.",
            alerts: [],
            plannedWorks: [],
            homeStationName: resolvedHomeStation,
            cityStationName: resolvedCityStation,
            homeStationDepartures: departures(startingAt: now + 300),
            homeStationAllDepartures: departures(startingAt: now + 300),
            cityStationDepartures: departures(startingAt: now + 600),
            cityStationAllDepartures: departures(startingAt: now + 600),
            melbourneTimeAtFetch: "--:-- --"
        )
    }
}
