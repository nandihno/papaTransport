import Foundation

/// A set of departures sharing a rider-facing direction, e.g. "City" or
/// "Werribee". Replaces grouping by line — see UIRevampPlan.md Phase 2 §2.2.
struct DepartureDirectionGroup: Identifiable {
    let label: String
    let isCityward: Bool
    let departures: [BusDeparture]

    var id: String { label }

    var nextDeparture: BusDeparture? { departures.first }
}

extension BusDeparture {
    /// Best-effort grouping key.
    ///
    /// PTV supplies a semantic direction name ("City", "Werribee", …) via
    /// `directionName`. GTFS-only feeds (Queensland) have no equivalent table
    /// — `direction_id` there is just 0/1 with no rider-facing meaning — so
    /// grouping falls back to `headsign`, which is what actually appears on
    /// the front of the vehicle and groups the same way in practice.
    var groupingLabel: String {
        if let directionName {
            let trimmed = directionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let headsign {
            let trimmed = headsign.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let route = routeShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return route.isEmpty ? "Other services" : route
    }
}

extension Array where Element == BusDeparture {
    /// Groups by `groupingLabel`, cityward first.
    ///
    /// The cityward test is an exact match on "City" — checked against all 17
    /// Victorian metro train routes, every one names its cityward direction
    /// literally that. The sole route with no cityward group is Stony Point
    /// (Frankston ↔ Stony Point), which is correct: it is the isolated shuttle
    /// with no through service to the city.
    func groupedByDirection() -> [DepartureDirectionGroup] {
        let grouped = Dictionary(grouping: self, by: \.groupingLabel)

        return grouped
            .map { label, departures in
                DepartureDirectionGroup(
                    label: label,
                    isCityward: label == "City",
                    departures: departures.sorted { $0.scheduledSeconds < $1.scheduledSeconds }
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCityward != rhs.isCityward { return lhs.isCityward }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }
}
