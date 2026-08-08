//
//  TrainService.swift
//  myLatest
//
//  Fetches Metro Trains Melbourne line status from `website_data.json`
//  (alerts, planned works, service state).
//
//  Departure boards do NOT come from here — they are served by the PTV
//  Timetable API via `PTVBoardService`, which supplies scheduled and estimated
//  times, platform and direction in one signed request. The old
//  `departures.json` and `op_timetable_<line_id>.json` feeds were removed once
//  PTV covered every field they provided; see UIRevampPlan.md Phase 2 §2.1.
//

import Foundation

final class TrainService {
    static let shared = TrainService()
    private init() {}

    private let statusURL = URL(string: "https://747813379903-static-assets-production.s3-ap-southeast-2.amazonaws.com/website_data.json")!

    // MARK: - Public API

    func fetchTrainInfo(lineName: String) async throws -> TrainInfo {
        // Trim whitespace/newlines that can sneak in from the Settings keyboard.
        let lineName = lineName.trimmingCharacters(in: .whitespacesAndNewlines)

        let (statusData, _) = try await URLSession.shared.data(from: statusURL)
        let allLines = try JSONDecoder().decode(WebsiteDataResponse.self, from: statusData)

        // Find the matching line by name (case-insensitive exact match first,
        // then partial match as fallback).
        let lineData = allLines.lines.first {
            $0.data.lineName.lowercased() == lineName.lowercased()
        }?.data ?? allLines.lines.first {
            $0.data.lineName.lowercased().contains(lineName.lowercased())
        }?.data

        let melbourneTime = Self.currentTimeString()

        guard let lineData else {
            return TrainInfo(
                lineName:             lineName.isEmpty ? "Unknown Line" : lineName,
                serviceIsGood:        true,
                serviceStatusMessage: lineName.isEmpty
                    ? "Set your train line name in Settings."
                    : "No status data found for \"\(lineName)\".",
                alerts:               [],
                plannedWorks:         [],
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
            melbourneTimeAtFetch: melbourneTime
        )
    }

    // MARK: - Time utilities

    /// Current Melbourne time formatted as "h:mm a" (e.g. "8:45 AM").
    static func currentTimeString() -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Australia/Melbourne")
        f.dateFormat = "h:mm a"
        return f.string(from: Date())
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
