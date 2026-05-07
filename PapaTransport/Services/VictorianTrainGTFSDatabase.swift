import CoreLocation
import Foundation
import SQLite3

actor VictorianTrainGTFSDatabase {
    static let shared = VictorianTrainGTFSDatabase()

    private var db: OpaquePointer?
    private var isImported = false

    private let bundledDatabaseFileName = "gtfs_victorian_train"
    private let bundledDatabaseExtension = "sqlite3"
    private let bundledDatabaseSubdirectory = "db/transport/victoria"

    private var dbPath: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_victorian_train.sqlite3").path
    }

    func hasBundledDatabaseAsset() -> Bool {
        bundledDatabaseAssetURL() != nil
    }

    func isDatabaseReady() -> Bool {
        if isImported && db != nil { return true }
        do {
            return try validateInstalledDatabase()
        } catch {
            return false
        }
    }

    func ensureReady() async throws {
        if isImported && db != nil { return }
        if try validateInstalledDatabase() { return }
        try await installBundledDatabase()
    }

    func refreshDatabase() async throws {
        closeDB()
        try removeCachedDatabaseArtifacts()
        try await installBundledDatabase()
    }

    func resetDatabase() throws {
        closeDB()
        try removeCachedDatabaseArtifacts()
    }

    // MARK: - Queries

    func stopsInRegion(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        limit: Int = 200
    ) throws -> [GTFSStop] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type IN (2, 400)
              AND location_type = 0
              AND stop_lat BETWEEN ? AND ?
              AND stop_lon BETWEEN ? AND ?
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, minLat)
        sqlite3_bind_double(stmt, 2, maxLat)
        sqlite3_bind_double(stmt, 3, minLon)
        sqlite3_bind_double(stmt, 4, maxLon)
        sqlite3_bind_int(stmt, 5, Int32(limit))

        var results: [GTFSStop] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                GTFSStop(
                    stopId: textColumn(stmt, index: 0),
                    stopName: textColumn(stmt, index: 1),
                    stopCode: optionalTextColumn(stmt, index: 2),
                    stopLat: sqlite3_column_double(stmt, 3),
                    stopLon: sqlite3_column_double(stmt, 4),
                    locationType: Int(sqlite3_column_int(stmt, 5)),
                    parentStation: optionalTextColumn(stmt, index: 6)
                )
            )
        }

        return results
    }

    /// Returns nearby train stations within `radiusMeters`, grouped by parent station
    /// so multi-platform stations (e.g. Flinders Street) appear as a single pin.
    func nearbyTrainStations(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 5000
    ) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        let latDelta = radiusMeters / 111_000.0
        let lonDelta = radiusMeters / (111_000.0 * cos(latitude * .pi / 180.0))
        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type IN (2, 400)
              AND location_type = 0
              AND stop_lat BETWEEN ? AND ?
              AND stop_lon BETWEEN ? AND ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, latitude - latDelta)
        sqlite3_bind_double(stmt, 2, latitude + latDelta)
        sqlite3_bind_double(stmt, 3, longitude - lonDelta)
        sqlite3_bind_double(stmt, 4, longitude + lonDelta)

        let userLocation = CLLocation(latitude: latitude, longitude: longitude)

        // Collect all stops, then group by parent_station to deduplicate platforms.
        var rawResults: [(GTFSStop, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let stop = GTFSStop(
                stopId: textColumn(stmt, index: 0),
                stopName: textColumn(stmt, index: 1),
                stopCode: optionalTextColumn(stmt, index: 2),
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: optionalTextColumn(stmt, index: 6)
            )
            let distance = userLocation.distance(from: CLLocation(latitude: stop.stopLat, longitude: stop.stopLon))
            if distance <= radiusMeters {
                rawResults.append((stop, distance))
            }
        }

        // Group by parent_station (or stop_id if no parent) — pick the closest platform.
        var bestByStation: [String: (GTFSStop, Double)] = [:]
        for (stop, distance) in rawResults {
            let key = stop.parentStation ?? stop.stopId
            if let existing = bestByStation[key] {
                if distance < existing.1 {
                    bestByStation[key] = (stop, distance)
                }
            } else {
                bestByStation[key] = (stop, distance)
            }
        }

        return bestByStation.values.sorted { $0.1 < $1.1 }
    }

    func stationsInRegion(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        referenceLatitude: Double,
        referenceLongitude: Double
    ) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type IN (2, 400)
              AND location_type = 0
              AND stop_lat BETWEEN ? AND ?
              AND stop_lon BETWEEN ? AND ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, minLat)
        sqlite3_bind_double(stmt, 2, maxLat)
        sqlite3_bind_double(stmt, 3, minLon)
        sqlite3_bind_double(stmt, 4, maxLon)

        let referenceLocation = CLLocation(latitude: referenceLatitude, longitude: referenceLongitude)
        var rawResults: [(GTFSStop, Double)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let stop = GTFSStop(
                stopId: textColumn(stmt, index: 0),
                stopName: textColumn(stmt, index: 1),
                stopCode: optionalTextColumn(stmt, index: 2),
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: optionalTextColumn(stmt, index: 6)
            )
            let distance = referenceLocation.distance(
                from: CLLocation(latitude: stop.stopLat, longitude: stop.stopLon)
            )
            rawResults.append((stop, distance))
        }

        var bestByStation: [String: (GTFSStop, Double)] = [:]
        for (stop, distance) in rawResults {
            let key = stop.parentStation ?? stop.stopId
            if let existing = bestByStation[key] {
                if distance < existing.1 {
                    bestByStation[key] = (stop, distance)
                }
            } else {
                bestByStation[key] = (stop, distance)
            }
        }

        return bestByStation.values.sorted { $0.1 < $1.1 }
    }

    /// Returns all stop IDs that share the same parent station (i.e. different platforms).
    func siblingStopIds(for stopId: String) throws -> [String] {
        guard let db else { throw GTFSDBError.notReady }

        // First get the parent_station for this stop.
        let parentSQL = "SELECT parent_station FROM stops WHERE stop_id = ?"
        var parentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, parentSQL, -1, &parentStmt, nil) == SQLITE_OK else {
            return [stopId]
        }
        defer { sqlite3_finalize(parentStmt) }
        sqlite3_bind_text(parentStmt, 1, (stopId as NSString).utf8String, -1, nil)

        var parentStation: String?
        if sqlite3_step(parentStmt) == SQLITE_ROW {
            parentStation = optionalTextColumn(parentStmt, index: 0)
        }

        guard let parent = parentStation, !parent.isEmpty else {
            return [stopId]
        }

        // Now find all stops with this parent_station.
        let siblingsSQL = "SELECT stop_id FROM stops WHERE parent_station = ?"
        var siblingsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, siblingsSQL, -1, &siblingsStmt, nil) == SQLITE_OK else {
            return [stopId]
        }
        defer { sqlite3_finalize(siblingsStmt) }
        sqlite3_bind_text(siblingsStmt, 1, (parent as NSString).utf8String, -1, nil)

        var ids: [String] = []
        while sqlite3_step(siblingsStmt) == SQLITE_ROW {
            ids.append(textColumn(siblingsStmt, index: 0))
        }

        return ids.isEmpty ? [stopId] : ids
    }

    func trainRoutes() throws -> [TrainRoute] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT route_id, route_short_name, route_long_name
            FROM routes
            WHERE route_type = 400
              AND route_short_name IS NOT NULL
              AND TRIM(route_short_name) <> ''
              AND route_short_name <> 'Replacement Bus'
            ORDER BY route_short_name COLLATE NOCASE ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [TrainRoute] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                TrainRoute(
                    routeId: textColumn(stmt, index: 0),
                    routeShortName: textColumn(stmt, index: 1),
                    routeLongName: textColumn(stmt, index: 2)
                )
            )
        }

        return results
    }

    func activeTripCandidates(
        routeShortName: String?,
        directionId: Int?,
        aroundSeconds: Int,
        windowSeconds: Int = 45 * 60,
        limit: Int = 120
    ) throws -> [ActiveTripCandidate] {
        guard let db else { throw GTFSDBError.notReady }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let routeClause = routeShortName == nil ? "" : "AND LOWER(r.route_short_name) = LOWER(?)"
        let directionClause = directionId == nil ? "" : "AND t.direction_id = ?"

        let sql = """
            SELECT t.trip_id, t.route_id, r.route_short_name, r.route_long_name,
                   t.trip_headsign, t.direction_id,
                   MIN(IFNULL(st.departure_seconds, st.arrival_seconds)) AS first_seconds,
                   MAX(IFNULL(st.arrival_seconds, st.departure_seconds)) AS last_seconds
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            JOIN stop_times st ON st.trip_id = t.trip_id
            WHERE t.service_id IN (\(servicePlaceholders))
              AND r.route_type = 400
              AND r.route_short_name <> 'Replacement Bus'
              \(routeClause)
              \(directionClause)
            GROUP BY t.trip_id, t.route_id, r.route_short_name, r.route_long_name,
                     t.trip_headsign, t.direction_id
            HAVING first_seconds <= ?
               AND last_seconds >= ?
            ORDER BY ABS(((first_seconds + last_seconds) / 2) - ?) ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }

        if let routeShortName {
            sqlite3_bind_text(stmt, index, (routeShortName as NSString).utf8String, -1, nil)
            index += 1
        }

        if let directionId {
            sqlite3_bind_int(stmt, index, Int32(directionId))
            index += 1
        }

        sqlite3_bind_int(stmt, index, Int32(aroundSeconds + windowSeconds))
        index += 1
        sqlite3_bind_int(stmt, index, Int32(aroundSeconds - windowSeconds))
        index += 1
        sqlite3_bind_int(stmt, index, Int32(aroundSeconds))
        index += 1
        sqlite3_bind_int(stmt, index, Int32(limit))

        var results: [ActiveTripCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                ActiveTripCandidate(
                    tripId: textColumn(stmt, index: 0),
                    routeId: textColumn(stmt, index: 1),
                    routeShortName: textColumn(stmt, index: 2),
                    routeLongName: textColumn(stmt, index: 3),
                    tripHeadsign: optionalTextColumn(stmt, index: 4),
                    directionId: Int(sqlite3_column_int(stmt, 5)),
                    firstSeconds: Int(sqlite3_column_int(stmt, 6)),
                    lastSeconds: Int(sqlite3_column_int(stmt, 7))
                )
            )
        }

        return results
    }

    func departures(
        forStopIds stopIds: [String],
        afterSeconds: Int,
        untilSeconds: Int? = nil
    ) throws -> [ScheduledDeparture] {
        guard let db else { throw GTFSDBError.notReady }
        guard !stopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let stopPlaceholders = stopIds.map { _ in "?" }.joined(separator: ",")
        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let untilClause = untilSeconds != nil ? "AND st.departure_seconds <= ?" : ""
        let sql = """
            SELECT st.trip_id, st.stop_id, st.departure_time, st.departure_seconds, st.stop_sequence,
                   t.route_id, t.trip_headsign, t.direction_id,
                   r.route_short_name, r.route_long_name,
                   s.stop_name
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            JOIN stops s ON st.stop_id = s.stop_id
            WHERE st.stop_id IN (\(stopPlaceholders))
              AND t.service_id IN (\(servicePlaceholders))
              AND st.departure_seconds >= ?
              \(untilClause)
              AND r.route_type IN (2, 400)
            ORDER BY st.departure_seconds ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        for stopId in stopIds {
            sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil)
            index += 1
        }
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(afterSeconds))
        if let untilSeconds {
            index += 1
            sqlite3_bind_int(stmt, index, Int32(untilSeconds))
        }

        var results: [ScheduledDeparture] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let routeShortName = textColumn(stmt, index: 8, fallback: "Train")
            let routeLongName = textColumn(stmt, index: 9, fallback: routeShortName)

            results.append(
                ScheduledDeparture(
                    tripId: textColumn(stmt, index: 0),
                    stopId: textColumn(stmt, index: 1),
                    departureTime: textColumn(stmt, index: 2),
                    departureSeconds: Int(sqlite3_column_int(stmt, 3)),
                    stopSequence: Int(sqlite3_column_int(stmt, 4)),
                    routeId: textColumn(stmt, index: 5),
                    tripHeadsign: optionalTextColumn(stmt, index: 6),
                    directionId: Int(sqlite3_column_int(stmt, 7)),
                    routeShortName: routeShortName,
                    routeLongName: routeLongName,
                    stopName: textColumn(stmt, index: 10)
                )
            )
        }

        return results
    }

    func tripPattern(tripId: String) throws -> [TripPatternStop] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT st.stop_id, s.stop_name, s.stop_code, s.stop_lat, s.stop_lon,
                   st.arrival_time, st.departure_time,
                   st.arrival_seconds, st.departure_seconds,
                   st.stop_sequence
            FROM stop_times st
            JOIN stops s ON st.stop_id = s.stop_id
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE st.trip_id = ?
              AND r.route_type IN (2, 400)
            ORDER BY st.stop_sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)

        var results: [TripPatternStop] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                TripPatternStop(
                    stopId: textColumn(stmt, index: 0),
                    stopName: textColumn(stmt, index: 1),
                    stopCode: optionalTextColumn(stmt, index: 2),
                    stopLat: sqlite3_column_double(stmt, 3),
                    stopLon: sqlite3_column_double(stmt, 4),
                    arrivalTime: optionalTextColumn(stmt, index: 5),
                    departureTime: optionalTextColumn(stmt, index: 6),
                    arrivalSeconds: Int(sqlite3_column_int(stmt, 7)),
                    departureSeconds: Int(sqlite3_column_int(stmt, 8)),
                    stopSequence: Int(sqlite3_column_int(stmt, 9))
                )
            )
        }

        return results
    }

    // MARK: - Shared types (same shape as VictorianBusGTFSDatabase)

    struct TrainRoute: Identifiable {
        let routeId: String
        let routeShortName: String
        let routeLongName: String

        var id: String { routeId }
    }

    struct ActiveTripCandidate {
        let tripId: String
        let routeId: String
        let routeShortName: String
        let routeLongName: String
        let tripHeadsign: String?
        let directionId: Int
        let firstSeconds: Int
        let lastSeconds: Int
    }

    struct ScheduledDeparture {
        let tripId: String
        let stopId: String
        let departureTime: String
        let departureSeconds: Int
        let stopSequence: Int
        let routeId: String
        let tripHeadsign: String?
        let directionId: Int
        let routeShortName: String
        let routeLongName: String
        let stopName: String
    }

    struct TripPatternStop {
        let stopId: String
        let stopName: String
        let stopCode: String?
        let stopLat: Double
        let stopLon: Double
        let arrivalTime: String?
        let departureTime: String?
        let arrivalSeconds: Int
        let departureSeconds: Int
        let stopSequence: Int
    }

    static func melbourneMidnightSeconds() -> Int {
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourne
        let now = Date()
        return calendar.component(.hour, from: now) * 3600
            + calendar.component(.minute, from: now) * 60
            + calendar.component(.second, from: now)
    }

    // MARK: - Database lifecycle

    private func installBundledDatabase() async throws {
        guard let bundledURL = bundledDatabaseAssetURL() else {
            throw GTFSDBError.bundledAssetMissing
        }

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Installing Victorian train data…",
                detail: "Copying the bundled timetable database"
            )
        }
        defer {
            Task { @MainActor in
                GTFSDownloadProgress.shared.finish()
            }
        }

        closeDB()
        try removeCachedDatabaseArtifacts()

        let destinationURL = URL(fileURLWithPath: dbPath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: bundledURL, to: destinationURL)

        guard try validateInstalledDatabase() else {
            throw GTFSDBError.notReady
        }
    }

    private func bundledDatabaseAssetURL() -> URL? {
        if let nested = Bundle.main.url(
            forResource: bundledDatabaseFileName,
            withExtension: bundledDatabaseExtension,
            subdirectory: bundledDatabaseSubdirectory
        ) {
            return nested
        }

        return Bundle.main.url(
            forResource: bundledDatabaseFileName,
            withExtension: bundledDatabaseExtension
        )
    }

    private func validateInstalledDatabase() throws -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }
        try openDB()
        let count = queryCount("SELECT COUNT(*) FROM stops")
        if count > 0 {
            isImported = true
            return true
        }
        closeDB()
        return false
    }

    private func todayActiveServiceIds() throws -> [String] {
        guard let db else { throw GTFSDBError.notReady }

        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourne
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = melbourne
        let dateString = formatter.string(from: now)

        let dayColumn: String = switch weekday {
        case 1: "sunday"
        case 2: "monday"
        case 3: "tuesday"
        case 4: "wednesday"
        case 5: "thursday"
        case 6: "friday"
        case 7: "saturday"
        default: "monday"
        }

        var activeIds = Set<String>()
        let baseSQL = """
            SELECT service_id FROM calendar
            WHERE \(dayColumn) = 1
              AND start_date <= ?
              AND end_date >= ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, baseSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (dateString as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                activeIds.insert(textColumn(stmt, index: 0))
            }
        }
        sqlite3_finalize(stmt)

        let exceptionSQL = "SELECT service_id, exception_type FROM calendar_dates WHERE date = ?"
        if sqlite3_prepare_v2(db, exceptionSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let serviceId = textColumn(stmt, index: 0)
                let exceptionType = sqlite3_column_int(stmt, 1)
                if exceptionType == 1 {
                    activeIds.insert(serviceId)
                } else if exceptionType == 2 {
                    activeIds.remove(serviceId)
                }
            }
        }
        sqlite3_finalize(stmt)

        return Array(activeIds)
    }

    private func openDB() throws {
        if db != nil { return }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw GTFSDBError.openFailed
        }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -16000")
    }

    private func closeDB() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
        isImported = false
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func queryCount(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func textColumn(_ stmt: OpaquePointer?, index: Int32, fallback: String = "") -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return fallback }
        return String(cString: raw)
    }

    private func optionalTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }

    private func removeCachedDatabaseArtifacts() throws {
        let fileManager = FileManager.default
        let dbURL = URL(fileURLWithPath: dbPath)
        let urls = [
            dbURL,
            URL(fileURLWithPath: "\(dbPath)-wal"),
            URL(fileURLWithPath: "\(dbPath)-shm"),
        ]

        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
