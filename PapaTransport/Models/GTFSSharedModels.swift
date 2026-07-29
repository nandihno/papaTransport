import Foundation

struct GTFSStop {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let stopLat: Double
    let stopLon: Double
    let locationType: Int
    let parentStation: String?
}

/// The date window a GTFS feed's `calendar` table actually covers.
///
/// TransLink publishes roughly a two-month window and republishes weekly. Past
/// `endDate` every query still succeeds and every table is still populated —
/// there is simply no active service for today, so departure boards render
/// empty. Without this the failure is silent.
/// `nonisolated` because this crosses isolation domains constantly — it is
/// produced inside the `GTFSDatabase` actor, evaluated by the importer on a
/// background queue, and read by main-actor views. The target defaults to
/// main-actor isolation, which would otherwise make all of that illegal.
nonisolated struct GTFSFeedValidity: Equatable, Sendable {
    /// `yyyyMMdd`, as stored by GTFS.
    let startDate: String
    let endDate: String

    enum Status: Equatable, Sendable {
        case current(daysRemaining: Int)
        case expiringSoon(daysRemaining: Int)
        case expired(daysAgo: Int)
        /// The feed starts in the future — a database built ahead of time.
        case notYetValid(daysUntil: Int)
    }

    /// Feeds are considered at risk once they are inside this many days of
    /// lapsing, which is when a background refresh should start trying.
    static let expiringSoonThresholdDays = 10

    private static let brisbane = TimeZone(identifier: "Australia/Brisbane")!

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = brisbane
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    var start: Date? { Self.formatter.date(from: startDate) }
    var end: Date? { Self.formatter.date(from: endDate) }

    func status(asOf now: Date = Date()) -> Status {
        guard let start, let end else { return .current(daysRemaining: 0) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.brisbane
        let today = calendar.startOfDay(for: now)

        if today < calendar.startOfDay(for: start) {
            let days = calendar.dateComponents([.day], from: today, to: start).day ?? 0
            return .notYetValid(daysUntil: days)
        }
        // `end` is inclusive: a feed ending today is still valid today.
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: end)).day ?? 0
        if days < 0 { return .expired(daysAgo: -days) }
        if days <= Self.expiringSoonThresholdDays { return .expiringSoon(daysRemaining: days) }
        return .current(daysRemaining: days)
    }

    func isUsable(asOf now: Date = Date()) -> Bool {
        switch status(asOf: now) {
        case .current, .expiringSoon: true
        case .expired, .notYetValid: false
        }
    }

    /// True once a background refresh is worth attempting.
    func shouldRefresh(asOf now: Date = Date()) -> Bool {
        switch status(asOf: now) {
        case .current: false
        case .expiringSoon, .expired, .notYetValid: true
        }
    }

    var displayEndDate: String {
        guard let end else { return endDate }
        return end.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

enum GTFSDBError: LocalizedError {
    case bundledAssetMissing
    case notReady
    case openFailed
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledAssetMissing:
            // Expected, not exceptional: shipping the database is optional, and
            // when it is absent the timetable is downloaded instead.
            return "No timetable is installed yet. It will be downloaded the next time you open Bus or Trains."
        case .notReady:
            return "The timetable database is not ready yet."
        case .openFailed:
            return "The timetable database could not be opened."
        case .queryFailed(let message):
            return "A timetable query failed: \(message)"
        }
    }
}
