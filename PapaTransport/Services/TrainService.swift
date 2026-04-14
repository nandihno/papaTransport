//
//  TrainService.swift
//  myLatest
//
//  Fetches real-time Metro Trains Melbourne data:
//    • website_data.json              — line status, alerts, planned works, line IDs
//    • departures.json                — real-time departure times per station
//    • op_timetable_<line_id>.json    — full operational timetable for Plan Ahead
//
//  website_data.json and departures.json are fetched concurrently.
//  The line ID extracted from website_data.json is then used to fetch the
//  operational timetable for the Plan Ahead feature.
//

import Foundation

final class TrainService {
    static let shared = TrainService()
    private init() {}

    private let statusURL     = URL(string: "https://747813379903-static-assets-production.s3-ap-southeast-2.amazonaws.com/website_data.json")!
    private let departuresURL = URL(string: "https://747813379903-static-assets-production.s3-ap-southeast-2.amazonaws.com/departures.json")!

    // MARK: - Public API

    func fetchTrainInfo(lineName: String,
                        homeStation: String,
                        cityStation: String) async throws -> TrainInfo {

        // Trim whitespace/newlines that can sneak in from the Settings keyboard.
        let lineName    = lineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let homeStation = homeStation.trimmingCharacters(in: .whitespacesAndNewlines)
        let cityStation = cityStation.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fetch both endpoints concurrently.
        async let statusFetch     = URLSession.shared.data(from: statusURL)
        async let departuresFetch = URLSession.shared.data(from: departuresURL)

        let (statusData,     _) = try await statusFetch
        let (departuresData, _) = try await departuresFetch

        let decoder = JSONDecoder()
        let allLines  = try decoder.decode(WebsiteDataResponse.self, from: statusData)
        let depsResp  = try decoder.decode(DeparturesAPIResponse.self, from: departuresData)

        // Find the matching line by name (case-insensitive exact match first,
        // then partial match as fallback).  Also capture the numeric line ID.
        let matchedLine: (lineId: String, data: TrainLineAPIData)? =
            allLines.lines.first {
                $0.data.lineName.lowercased() == lineName.lowercased()
            } ?? allLines.lines.first {
                $0.data.lineName.lowercased().contains(lineName.lowercased())
            }
        let lineData = matchedLine?.data
        let lineId   = matchedLine?.lineId

        // Current Melbourne time in seconds since midnight — used to filter
        // out trains that have already departed.
        let nowSeconds    = Self.secondsSinceMidnight()
        let melbourneTime = Self.currentTimeString()

        // Home station: show BOTH inbound and outbound
        let homeDeps = filterAndMapDepartures(depsResp.entries,
                                              station: homeStation,
                                              currentSeconds: nowSeconds,
                                              toCityOnly: nil)
        // ── Plan Ahead: full timetable from op_timetable endpoint ─────
        // Fetch the full operational timetable for the line so Plan Ahead
        // can show departures at any future time, not just near-current ones.
        var homeAllDeps: [TrainDeparture] = []
        var cityAllDeps: [TrainDeparture] = []
        if let lineId {
            let timetableEntries = try await fetchTimetable(lineId: lineId)
            homeAllDeps = filterAndMapTimetable(timetableEntries,
                                                station: homeStation,
                                                toCityOnly: nil)
            cityAllDeps = filterAndMapTimetable(timetableEntries,
                                                station: cityStation,
                                                toCityOnly: nil)
        }

        // City station: both inbound and outbound departures from the
        // timetable endpoint, filtered to now → now + 30 minutes.
        let cityDeps: [TrainDeparture] = {
            guard !cityAllDeps.isEmpty else { return [] }
            let maxSeconds = nowSeconds + 1800  // +30 minutes
            return cityAllDeps.filter {
                $0.estimatedDepartureSeconds >= nowSeconds &&
                $0.estimatedDepartureSeconds <= maxSeconds
            }
        }()

        guard let lineData else {
            // Line name not matched — return a minimal result with departures only.
            return TrainInfo(
                lineName:             lineName.isEmpty ? "Unknown Line" : lineName,
                serviceIsGood:        true,
                serviceStatusMessage: lineName.isEmpty
                    ? "Set your train line name in Settings."
                    : "No status data found for \"\(lineName)\".",
                alerts:               [],
                plannedWorks:         [],
                homeStationName:      homeStation,
                cityStationName:      cityStation,
                homeStationDepartures: homeDeps,
                homeStationAllDepartures: homeAllDeps,
                cityStationDepartures: cityDeps,
                cityStationAllDepartures: cityAllDeps,
                melbourneTimeAtFetch: melbourneTime
            )
        }

        // ── Map alerts ────────────────────────────────────────────────────
        let (serviceIsGood, statusMessage, alerts): (Bool, String, [TrainServiceAlert]) = {
            switch lineData.alertsPayload {
            case .message(let msg):
                return (true, msg, [])
            case .items(let items):
                let mapped = items.map { item -> TrainServiceAlert in
                    let mins = item.additionalTravelTime.flatMap { Int($0) }
                    let dueTo: String? = {
                        guard let s = item.disruptionDueTo, !s.isEmpty else { return nil }
                        return s
                    }()
                    return TrainServiceAlert(
                        id:                     item.alertId,
                        alertType:              item.alertType,
                        plainText:              item.alertText.strippingHTML,
                        additionalTravelMinutes: mins,
                        disruptionDueTo:        dueTo
                    )
                }
                let firstSummary = mapped.first?.plainText ?? "Service disruption"
                return (false, firstSummary, mapped)
            }
        }()

        // ── Map planned works ─────────────────────────────────────────────
        let plannedWorks = lineData.plannedWorksList.map { item in
            TrainPlannedWork(
                id:               item.id,
                title:            item.title,
                link:             item.link,
                type:             item.type,
                upcomingCurrent:  item.upcomingCurrent,
                affectedStations: item.affectedStations
            )
        }

        return TrainInfo(
            lineName:             lineData.lineName,
            serviceIsGood:        serviceIsGood,
            serviceStatusMessage: statusMessage,
            alerts:               alerts,
            plannedWorks:         plannedWorks,
            homeStationName:      homeStation,
            cityStationName:      cityStation,
            homeStationDepartures: homeDeps,
            homeStationAllDepartures: homeAllDeps,
            cityStationDepartures: cityDeps,
            cityStationAllDepartures: cityAllDeps,
            melbourneTimeAtFetch: melbourneTime
        )
    }

    // MARK: - Timetable (Plan Ahead)

    /// Fetch the full operational timetable for a line from the static S3 endpoint.
    private func fetchTimetable(lineId: String) async throws -> [TimetableAPIEntry] {
        let url = URL(string: "https://747813379903-static-assets-production.s3-ap-southeast-2.amazonaws.com/op_timetable_\(lineId).json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([TimetableAPIEntry].self, from: data)
    }

    /// Filter timetable entries by station name and direction, returning TrainDeparture models.
    /// No time filtering is applied — the Plan Ahead UI handles the window.
    private func filterAndMapTimetable(_ entries: [TimetableAPIEntry],
                                       station: String,
                                       toCityOnly: Bool?) -> [TrainDeparture] {
        guard !station.isEmpty else { return [] }
        let query = station.lowercased()

        return entries
            .filter { entry in
                let name = entry.station.lowercased()
                guard name.contains(query) || query.contains(name) else { return false }
                guard entry.isArrival == "0" else { return false }
                if let toCityOnly {
                    guard (entry.toCity == "1") == toCityOnly else { return false }
                }
                return true
            }
            .sorted { (Int($0.timeSeconds) ?? 0) < (Int($1.timeSeconds) ?? 0) }
            .map { entry in
                let secs = Int(entry.timeSeconds) ?? 0
                return TrainDeparture(
                    station:                   entry.station,
                    isToCity:                  entry.toCity == "1",
                    scheduledTimeStr:          entry.timeStr,
                    estimatedArrivalStr:       entry.timeStr,   // timetable has no estimates
                    estimatedDepartureStr:     entry.timeStr,
                    estimatedDepartureSeconds: secs,
                    platform:                  entry.platform,
                    estimatedPlatform:         entry.platform
                )
            }
    }

    // MARK: - Private helpers

    /// - Parameter toCityOnly: `true` = inbound only, `false` = outbound only, `nil` = both directions.
    /// - Parameter limit: Maximum number of results.  Pass `nil` for unlimited.
    private func filterAndMapDepartures(_ entries: [DepartureAPIEntry],
                                        station: String,
                                        currentSeconds: Int,
                                        toCityOnly: Bool?,
                                        limit: Int? = 10) -> [TrainDeparture] {
        guard !station.isEmpty else { return [] }
        let query = station.lowercased()

        let filtered = entries
            .filter { entry in
                // Case-insensitive partial match (bidirectional)
                let name = entry.station.lowercased()
                guard name.contains(query) || query.contains(name) else { return false }
                // Departures only, not arrivals
                guard entry.isArrival == "0" else { return false }
                // Only upcoming (estimated departure >= now)
                guard entry.estimatedDepartureTimeSeconds >= currentSeconds else { return false }
                // Direction filter (nil = no filter)
                if let toCityOnly {
                    guard (entry.toCity == "1") == toCityOnly else { return false }
                }
                return true
            }
            .sorted { $0.estimatedDepartureTimeSeconds < $1.estimatedDepartureTimeSeconds }

        let limited = limit.map { Array(filtered.prefix($0)) } ?? filtered
        return limited
            .map { entry in
                TrainDeparture(
                    station:                entry.station,
                    isToCity:               entry.toCity == "1",
                    scheduledTimeStr:       entry.timeStr,
                    estimatedArrivalStr:    entry.estimatedArrivalTimeStr,
                    estimatedDepartureStr:  entry.estimatedDepartureTimeStr,
                    estimatedDepartureSeconds: entry.estimatedDepartureTimeSeconds,
                    platform:              entry.platform,
                    estimatedPlatform:     entry.estimatedPlatform
                )
            }
    }

    // MARK: - Time utilities (static so MockDataService can reuse them)

    /// Seconds elapsed since midnight in Melbourne local time.
    static func secondsSinceMidnight() -> Int {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let c = cal.dateComponents([.hour, .minute, .second], from: Date())
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// Current Melbourne time formatted as "h:mm a" (e.g. "8:45 AM").
    static func currentTimeString() -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Australia/Melbourne")
        f.dateFormat = "h:mm a"
        return f.string(from: Date())
    }

    /// Convert seconds-since-midnight to a "h:mm a" string.
    static func secondsToTimeString(_ seconds: Int) -> String {
        let h   = (seconds / 3600) % 24
        let m   = (seconds % 3600) / 60
        let ampm = h >= 12 ? "PM" : "AM"
        let h12  = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return String(format: "%d:%02d %@", h12, m, ampm)
    }
}

// MARK: - HTML stripping

extension String {
    /// Returns the receiver with all HTML tags removed and common entities decoded.
    var strippingHTML: String {
        var s = self
        // Strip tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common entities
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&nbsp;": " ", "&#8211;": "–", "&#8212;": "—",
            "&rsquo;": "'", "&lsquo;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse whitespace and newlines
        return s
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
