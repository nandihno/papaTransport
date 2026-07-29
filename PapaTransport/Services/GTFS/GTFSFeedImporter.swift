import Foundation
import SQLite3

nonisolated private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a `gtfs_seq.sqlite3` from a downloaded SEQ_GTFS.zip, on device.
///
/// Mirrors `scripts/build_seq_db.sh` — the two must stay in step, because a
/// database produced here has to be indistinguishable from the bundled one.
/// The output goes to a scratch path and is only swapped in after it verifies,
/// so a failed or interrupted import can never leave a half-written timetable
/// where the app expects a good one.
/// `nonisolated` is load-bearing: the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this type would
/// be implicitly main-actor-isolated and the whole import — 153 MB of inflate
/// and 2.7 million inserts — would run on the main thread and freeze the UI.
nonisolated struct GTFSFeedImporter {
    enum ImportError: LocalizedError {
        case missingFile(String)
        case openFailed
        case sqlFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let name):
                "The timetable download is missing \(name)."
            case .openFailed:
                "A new timetable database could not be created."
            case .sqlFailed(let message):
                "Importing the timetable failed: \(message)."
            case .verificationFailed(let reason):
                "The imported timetable failed its checks: \(reason)."
            }
        }
    }

    /// Files actually needed. `shapes.txt` is 37 MB and unused by any query,
    /// and `agency.txt` has no table — skipping both saves real time.
    private static let requiredFiles = [
        "stops.txt", "routes.txt", "trips.txt",
        "stop_times.txt", "calendar.txt", "calendar_dates.txt",
    ]

    let archiveURL: URL
    let destinationPath: String
    /// Reports 0…1 for the whole import, plus a human-readable stage.
    let onProgress: @Sendable (String, Double) -> Void

    func run() throws -> GTFSFeedValidity {
        let archive = try ZipArchive(fileURL: archiveURL)

        for name in Self.requiredFiles where archive.entry(named: name) == nil {
            throw ImportError.missingFile(name)
        }

        let scratchPath = destinationPath + ".import"
        try? FileManager.default.removeItem(atPath: scratchPath)

        var db: OpaquePointer?
        guard sqlite3_open(scratchPath, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ImportError.openFailed
        }
        var shouldCloseDB = true
        defer { if shouldCloseDB { sqlite3_close(db) } }

        try exec(db, """
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -20000;
            """)
        try exec(db, Self.schemaSQL)

        // Weights are roughly proportional to uncompressed bytes so the bar
        // does not stall for a minute on stop_times.
        let weights: [String: Double] = [
            "stops.txt": 0.01, "routes.txt": 0.01, "calendar.txt": 0.01,
            "calendar_dates.txt": 0.01, "trips.txt": 0.06, "stop_times.txt": 0.75,
        ]
        var completed = 0.0

        try exec(db, "BEGIN")
        for name in Self.requiredFiles {
            guard let entry = archive.entry(named: name) else {
                throw ImportError.missingFile(name)
            }
            onProgress("Importing \(name)", completed)
            try importEntry(entry, from: archive, into: db) { fraction in
                onProgress("Importing \(name)", completed + (weights[name] ?? 0) * fraction)
            }
            completed += weights[name] ?? 0
        }
        try exec(db, "COMMIT")

        onProgress("Linking bus stops", 0.86)
        // The denormalisation GTFSDatabase depends on: bus stops carry
        // route_type 3, everything else — rail included — stays -1.
        try exec(db, """
            UPDATE stops SET route_type = 3 WHERE stop_id IN (
                SELECT DISTINCT st.stop_id
                FROM stop_times st
                JOIN trips t  ON t.trip_id  = st.trip_id
                JOIN routes r ON r.route_id = t.route_id
                WHERE r.route_type = 3
            )
            """)

        onProgress("Building indexes", 0.90)
        try exec(db, Self.indexSQL)

        onProgress("Optimising", 0.97)
        try exec(db, "ANALYZE")

        let validity = try verify(db)

        shouldCloseDB = false
        sqlite3_close(db)

        try? FileManager.default.removeItem(atPath: destinationPath)
        try FileManager.default.moveItem(atPath: scratchPath, toPath: destinationPath)

        onProgress("Timetable updated", 1.0)
        return validity
    }

    // MARK: - Per-file import

    private func importEntry(
        _ entry: ZipArchive.Entry,
        from archive: ZipArchive,
        into db: OpaquePointer,
        progress: (Double) -> Void
    ) throws {
        var reader = CSVRowReader()
        var header: [String: Int] = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        var bytesSeen = 0
        var rowIndex = 0
        var lastReported = 0.0

        let binder = try binder(for: entry.name, db: db, statement: &statement)

        try archive.stream(entry) { chunk in
            bytesSeen += chunk.count
            try reader.consume(chunk) { buffer, fields in
                defer { rowIndex += 1 }

                guard rowIndex > 0 else {
                    for (index, range) in fields.enumerated() {
                        let key = buffer.string(range)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            // Strip a UTF-8 BOM on the first column if present.
                            .replacingOccurrences(of: "\u{FEFF}", with: "")
                        header[key] = index
                    }
                    return
                }

                guard let statement else { return }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard binder(buffer, fields, header, statement) else { return }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw ImportError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
            }

            let fraction = Double(bytesSeen) / Double(max(entry.uncompressedSize, 1))
            if fraction - lastReported > 0.02 {
                lastReported = fraction
                progress(fraction)
            }
        }

        try reader.finish { buffer, fields in
            guard rowIndex > 0, let statement else { return }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard binder(buffer, fields, header, statement) else { return }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ImportError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Returns a closure that binds one CSV row onto a prepared statement.
    /// Columns are resolved by header name, so a reordered feed still imports.
    private typealias Binder = (UnsafeRawBufferPointer, [Range<Int>], [String: Int], OpaquePointer) -> Bool

    private func binder(
        for fileName: String,
        db: OpaquePointer,
        statement: inout OpaquePointer?
    ) throws -> Binder {
        func prepare(_ sql: String) throws {
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ImportError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
        }

        func text(_ buffer: UnsafeRawBufferPointer, _ range: Range<Int>, _ stmt: OpaquePointer, _ column: Int32) {
            if range.isEmpty {
                sqlite3_bind_null(stmt, column)
            } else {
                let slice = UnsafeRawBufferPointer(rebasing: buffer[range])
                sqlite3_bind_text(stmt, column, slice.baseAddress!.assumingMemoryBound(to: CChar.self),
                                  Int32(range.count), SQLITE_TRANSIENT)
            }
        }

        func field(_ fields: [Range<Int>], _ header: [String: Int], _ name: String) -> Range<Int>? {
            guard let index = header[name], index < fields.count else { return nil }
            return fields[index]
        }

        switch fileName {
        case "stops.txt":
            try prepare("""
                INSERT OR REPLACE INTO stops
                (stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station, route_type)
                VALUES (?, ?, ?, ?, ?, ?, ?, -1)
                """)
            return { buffer, fields, header, stmt in
                guard let id = field(fields, header, "stop_id"), !id.isEmpty,
                      let latRange = field(fields, header, "stop_lat"),
                      let lonRange = field(fields, header, "stop_lon"),
                      let lat = buffer.double(latRange), let lon = buffer.double(lonRange)
                else { return false }

                text(buffer, id, stmt, 1)
                text(buffer, field(fields, header, "stop_name") ?? id, stmt, 2)
                text(buffer, field(fields, header, "stop_code") ?? (0..<0), stmt, 3)
                sqlite3_bind_double(stmt, 4, lat)
                sqlite3_bind_double(stmt, 5, lon)
                sqlite3_bind_int(stmt, 6, Int32(field(fields, header, "location_type").flatMap { buffer.int($0) } ?? 0))
                text(buffer, field(fields, header, "parent_station") ?? (0..<0), stmt, 7)
                return true
            }

        case "routes.txt":
            try prepare("""
                INSERT OR REPLACE INTO routes
                (route_id, route_short_name, route_long_name, route_type) VALUES (?, ?, ?, ?)
                """)
            return { buffer, fields, header, stmt in
                guard let id = field(fields, header, "route_id"), !id.isEmpty,
                      let typeRange = field(fields, header, "route_type"),
                      let type = buffer.int(typeRange)
                else { return false }

                text(buffer, id, stmt, 1)
                text(buffer, field(fields, header, "route_short_name") ?? (0..<0), stmt, 2)
                text(buffer, field(fields, header, "route_long_name") ?? (0..<0), stmt, 3)
                sqlite3_bind_int(stmt, 4, Int32(type))
                return true
            }

        case "trips.txt":
            try prepare("""
                INSERT OR REPLACE INTO trips
                (trip_id, route_id, service_id, trip_headsign, direction_id) VALUES (?, ?, ?, ?, ?)
                """)
            return { buffer, fields, header, stmt in
                guard let id = field(fields, header, "trip_id"), !id.isEmpty,
                      let routeId = field(fields, header, "route_id"),
                      let serviceId = field(fields, header, "service_id")
                else { return false }

                text(buffer, id, stmt, 1)
                text(buffer, routeId, stmt, 2)
                text(buffer, serviceId, stmt, 3)
                text(buffer, field(fields, header, "trip_headsign") ?? (0..<0), stmt, 4)
                sqlite3_bind_int(stmt, 5, Int32(field(fields, header, "direction_id").flatMap { buffer.int($0) } ?? 0))
                return true
            }

        case "stop_times.txt":
            try prepare("""
                INSERT INTO stop_times
                (trip_id, stop_id, arrival_time, departure_time, stop_sequence, arrival_seconds, departure_seconds)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            return { buffer, fields, header, stmt in
                guard let tripId = field(fields, header, "trip_id"), !tripId.isEmpty,
                      let stopId = field(fields, header, "stop_id"),
                      let sequenceRange = field(fields, header, "stop_sequence"),
                      let sequence = buffer.int(sequenceRange)
                else { return false }

                let arrival = field(fields, header, "arrival_time") ?? (0..<0)
                let departure = field(fields, header, "departure_time") ?? (0..<0)

                text(buffer, tripId, stmt, 1)
                text(buffer, stopId, stmt, 2)
                text(buffer, arrival, stmt, 3)
                text(buffer, departure, stmt, 4)
                sqlite3_bind_int(stmt, 5, Int32(sequence))

                if let seconds = buffer.gtfsSeconds(arrival) {
                    sqlite3_bind_int(stmt, 6, Int32(seconds))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let seconds = buffer.gtfsSeconds(departure) {
                    sqlite3_bind_int(stmt, 7, Int32(seconds))
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                return true
            }

        case "calendar.txt":
            try prepare("""
                INSERT OR REPLACE INTO calendar
                (service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            return { buffer, fields, header, stmt in
                guard let id = field(fields, header, "service_id"), !id.isEmpty,
                      let start = field(fields, header, "start_date"),
                      let end = field(fields, header, "end_date")
                else { return false }

                text(buffer, id, stmt, 1)
                let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
                for (offset, day) in days.enumerated() {
                    let value = field(fields, header, day).flatMap { buffer.int($0) } ?? 0
                    sqlite3_bind_int(stmt, Int32(offset + 2), Int32(value))
                }
                text(buffer, start, stmt, 9)
                text(buffer, end, stmt, 10)
                return true
            }

        case "calendar_dates.txt":
            try prepare("""
                INSERT INTO calendar_dates (service_id, date, exception_type) VALUES (?, ?, ?)
                """)
            return { buffer, fields, header, stmt in
                guard let id = field(fields, header, "service_id"), !id.isEmpty,
                      let date = field(fields, header, "date"),
                      let typeRange = field(fields, header, "exception_type"),
                      let type = buffer.int(typeRange)
                else { return false }

                text(buffer, id, stmt, 1)
                text(buffer, date, stmt, 2)
                sqlite3_bind_int(stmt, 3, Int32(type))
                return true
            }

        default:
            throw ImportError.missingFile(fileName)
        }
    }

    // MARK: - Verification

    private func verify(_ db: OpaquePointer) throws -> GTFSFeedValidity {
        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW
            else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }

        for table in ["stops", "routes", "trips", "stop_times", "calendar"] where count(table) == 0 {
            throw ImportError.verificationFailed("\(table) is empty")
        }
        guard count("stops WHERE route_type = 3") > 0 else {
            throw ImportError.verificationFailed("no bus stops were linked")
        }

        func text(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW,
                  let raw = sqlite3_column_text(stmt, 0)
            else { return nil }
            return String(cString: raw)
        }

        guard let start = text("SELECT MIN(start_date) FROM calendar"),
              let end = text("SELECT MAX(end_date) FROM calendar"),
              start.count == 8, end.count == 8
        else {
            throw ImportError.verificationFailed("the feed has no service calendar")
        }

        let validity = GTFSFeedValidity(startDate: start, endDate: end)
        guard validity.isUsable() else {
            // Refusing here matters: installing a feed that does not cover
            // today would replace working data with an empty board.
            throw ImportError.verificationFailed("it does not cover today")
        }
        return validity
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw ImportError.sqlFailed(message)
        }
    }

    // MARK: - Schema (keep in step with scripts/build_seq_db.sh)

    private static let schemaSQL = """
        CREATE TABLE stops (
            stop_id TEXT PRIMARY KEY,
            stop_name TEXT NOT NULL,
            stop_code TEXT,
            stop_lat REAL NOT NULL,
            stop_lon REAL NOT NULL,
            location_type INTEGER DEFAULT 0,
            parent_station TEXT,
            route_type INTEGER DEFAULT -1
        );
        CREATE TABLE routes (
            route_id TEXT PRIMARY KEY,
            route_short_name TEXT,
            route_long_name TEXT,
            route_type INTEGER NOT NULL
        );
        CREATE TABLE trips (
            trip_id TEXT PRIMARY KEY,
            route_id TEXT NOT NULL,
            service_id TEXT NOT NULL,
            trip_headsign TEXT,
            direction_id INTEGER DEFAULT 0
        );
        CREATE TABLE stop_times (
            trip_id TEXT NOT NULL,
            stop_id TEXT NOT NULL,
            arrival_time TEXT,
            departure_time TEXT,
            stop_sequence INTEGER NOT NULL,
            arrival_seconds INTEGER,
            departure_seconds INTEGER
        );
        CREATE TABLE calendar (
            service_id TEXT PRIMARY KEY,
            monday INTEGER, tuesday INTEGER, wednesday INTEGER,
            thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER,
            start_date TEXT, end_date TEXT
        );
        CREATE TABLE calendar_dates (
            service_id TEXT NOT NULL,
            date TEXT NOT NULL,
            exception_type INTEGER NOT NULL
        );
        """

    private static let indexSQL = """
        CREATE INDEX idx_stop_times_stop ON stop_times(stop_id, departure_seconds);
        CREATE INDEX idx_stop_times_trip ON stop_times(trip_id);
        CREATE INDEX idx_trips_route ON trips(route_id);
        CREATE INDEX idx_trips_service ON trips(service_id);
        CREATE INDEX idx_stops_location ON stops(stop_lat, stop_lon);
        CREATE INDEX idx_calendar_dates_date ON calendar_dates(date);
        """
}
