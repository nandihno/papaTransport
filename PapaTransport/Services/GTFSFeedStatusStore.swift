import Combine
import Foundation

/// Tracks how much life is left in the installed Queensland timetable.
///
/// Queensland is the only region still backed by a local schedule database —
/// TransLink publishes GTFS and GTFS-realtime but no timetable query API, so
/// there is nothing to offload the schedule to. That database covers a fixed
/// date window, and past it the app returns no departures at all while looking
/// perfectly healthy. This store makes that state observable.
@MainActor
final class GTFSFeedStatusStore: ObservableObject {
    static let shared = GTFSFeedStatusStore()

    @Published private(set) var validity: GTFSFeedValidity?
    @Published private(set) var status: GTFSFeedValidity.Status?

    private init() {}

    func refresh() async {
        let validity = await GTFSDatabase.shared.feedValidity()
        self.validity = validity
        self.status = validity?.status()
    }

    /// Copy for the banner, or nil when the feed is comfortably current.
    var warning: (title: String, detail: String, isError: Bool)? {
        guard let status, let validity else { return nil }

        switch status {
        case .current:
            return nil

        case .expiringSoon(let days):
            let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
            return (
                "Timetable expires \(when)",
                "The Queensland schedule covers services up to \(validity.displayEndDate). Departures will stop appearing after that until it is updated.",
                false
            )

        case .expired(let daysAgo):
            let ago = daysAgo == 1 ? "yesterday" : "\(daysAgo) days ago"
            return (
                "Timetable out of date",
                "The Queensland schedule ran out \(ago) (it covered services up to \(validity.displayEndDate)). Scheduled departures cannot be shown until it is updated. Live disruption alerts still work.",
                true
            )

        case .notYetValid(let daysUntil):
            return (
                "Timetable not active yet",
                "The installed Queensland schedule starts in \(daysUntil) day\(daysUntil == 1 ? "" : "s"). Departures will appear from then.",
                true
            )
        }
    }
}
