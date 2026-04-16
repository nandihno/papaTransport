import CoreLocation
import Foundation
import SQLite3

actor GTFSDatabase {
    static let shared = GTFSDatabase()

    private var db: OpaquePointer?
    private var isImported = false

    /// Cached set of stop_ids served by rail routes (route_type = 2).
    /// Built once on first access — avoids re-scanning the million-row stop_times table
    /// on every map pan. Nil means not yet computed.
    private var railStopIdCache: Set<String>?

    private let bundledDatabaseFileName = "gtfs_seq"
    private let bundledDatabaseExtension = "sqlite3"
    private let bundledDatabaseSubdirectory = "db/transport/queensland"

    private var dbPath: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_seq.sqlite3").path
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

    func stopsInRegion(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        limit: Int = 100
    ) throws -> [GTFSStop] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type = 3
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
                    stopId: String(cString: sqlite3_column_text(stmt, 0)),
                    stopName: String(cString: sqlite3_column_text(stmt, 1)),
                    stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    stopLat: sqlite3_column_double(stmt, 3),
                    stopLon: sqlite3_column_double(stmt, 4),
                    locationType: Int(sqlite3_column_int(stmt, 5)),
                    parentStation: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                )
            )
        }

        return results
    }

    func nearbyBusStops(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 300
    ) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        let latDelta = radiusMeters / 111_000.0
        let lonDelta = radiusMeters / (111_000.0 * cos(latitude * .pi / 180.0))
        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type = 3
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
        var results: [(GTFSStop, Double)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let stop = GTFSStop(
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            )
            let stopLocation = CLLocation(latitude: stop.stopLat, longitude: stop.stopLon)
            let distance = userLocation.distance(from: stopLocation)
            if distance <= radiusMeters {
                results.append((stop, distance))
            }
        }

        return results.sorted { $0.1 < $1.1 }
    }

    func departures(
        forStopIds stopIds: [String],
        afterSeconds: Int,
        limitPerStop: Int = 10
    ) throws -> [ScheduledDeparture] {
        guard let db else { throw GTFSDBError.notReady }
        guard !stopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let stopPlaceholders = stopIds.map { _ in "?" }.joined(separator: ",")
        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
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
              AND r.route_type = 3
            ORDER BY st.departure_seconds ASC
            LIMIT ?
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
        index += 1
        sqlite3_bind_int(stmt, index, Int32(limitPerStop * stopIds.count))

        var results: [ScheduledDeparture] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                ScheduledDeparture(
                    tripId: String(cString: sqlite3_column_text(stmt, 0)),
                    stopId: String(cString: sqlite3_column_text(stmt, 1)),
                    departureTime: String(cString: sqlite3_column_text(stmt, 2)),
                    departureSeconds: Int(sqlite3_column_int(stmt, 3)),
                    stopSequence: Int(sqlite3_column_int(stmt, 4)),
                    routeId: String(cString: sqlite3_column_text(stmt, 5)),
                    tripHeadsign: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                    directionId: Int(sqlite3_column_int(stmt, 7)),
                    routeShortName: String(cString: sqlite3_column_text(stmt, 8)),
                    routeLongName: String(cString: sqlite3_column_text(stmt, 9)),
                    stopName: String(cString: sqlite3_column_text(stmt, 10))
                )
            )
        }

        return results
    }

    // MARK: - Train Queries (route_type = 2)

    /// Returns (and caches) the set of all stop_ids served by rail routes.
    /// This query is expensive (full stop_times scan) but only runs once per app launch.
    private func cachedRailStopIds() throws -> Set<String> {
        if let cached = railStopIdCache { return cached }
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT DISTINCT st.stop_id
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 2
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var ids = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        railStopIdCache = ids
        return ids
    }

    func nearbyTrainStations(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 5000
    ) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        let latDelta = radiusMeters / 111_000.0
        let lonDelta = radiusMeters / (111_000.0 * cos(latitude * .pi / 180.0))
        let railIds = try cachedRailStopIds()

        // Bounding-box query only — rail filtering done in Swift using the cached set.
        // This avoids the expensive stop_times subquery on every call.
        let sql = """
            SELECT DISTINCT s.stop_id, s.stop_name, s.stop_code, s.stop_lat, s.stop_lon,
                            s.location_type, s.parent_station
            FROM stops s
            WHERE s.location_type = 0
              AND s.stop_lat BETWEEN ? AND ?
              AND s.stop_lon BETWEEN ? AND ?
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
        var rawResults: [(GTFSStop, Double)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let stop = GTFSStop(
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            )
            guard railIds.contains(stop.stopId) else { continue }
            let distance = userLocation.distance(from: CLLocation(latitude: stop.stopLat, longitude: stop.stopLon))
            if distance <= radiusMeters {
                rawResults.append((stop, distance))
            }
        }

        // Group by parent station to avoid duplicate entries per platform
        var bestByStation: [String: (GTFSStop, Double)] = [:]
        for (stop, distance) in rawResults {
            let key = stop.parentStation ?? stop.stopId
            if let existing = bestByStation[key] {
                if distance < existing.1 { bestByStation[key] = (stop, distance) }
            } else {
                bestByStation[key] = (stop, distance)
            }
        }

        return bestByStation.values.sorted { $0.1 < $1.1 }
    }

    func trainStationsInRegion(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        referenceLatitude: Double,
        referenceLongitude: Double
    ) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        let railIds = try cachedRailStopIds()

        // Bounding-box only — rail filtering done in Swift using the cached set.
        let sql = """
            SELECT DISTINCT s.stop_id, s.stop_name, s.stop_code, s.stop_lat, s.stop_lon,
                            s.location_type, s.parent_station
            FROM stops s
            WHERE s.location_type = 0
              AND s.stop_lat BETWEEN ? AND ?
              AND s.stop_lon BETWEEN ? AND ?
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
                stopId: String(cString: sqlite3_column_text(stmt, 0)),
                stopName: String(cString: sqlite3_column_text(stmt, 1)),
                stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                stopLat: sqlite3_column_double(stmt, 3),
                stopLon: sqlite3_column_double(stmt, 4),
                locationType: Int(sqlite3_column_int(stmt, 5)),
                parentStation: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            )
            guard railIds.contains(stop.stopId) else { continue }
            let distance = referenceLocation.distance(from: CLLocation(latitude: stop.stopLat, longitude: stop.stopLon))
            rawResults.append((stop, distance))
        }

        var bestByStation: [String: (GTFSStop, Double)] = [:]
        for (stop, distance) in rawResults {
            let key = stop.parentStation ?? stop.stopId
            if let existing = bestByStation[key] {
                if distance < existing.1 { bestByStation[key] = (stop, distance) }
            } else {
                bestByStation[key] = (stop, distance)
            }
        }

        return bestByStation.values.sorted { $0.1 < $1.1 }
    }

    func trainSiblingStopIds(for stopId: String) throws -> [String] {
        guard let db else { throw GTFSDBError.notReady }

        let parentSQL = "SELECT parent_station FROM stops WHERE stop_id = ?"
        var parentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, parentSQL, -1, &parentStmt, nil) == SQLITE_OK else {
            return [stopId]
        }
        defer { sqlite3_finalize(parentStmt) }
        sqlite3_bind_text(parentStmt, 1, (stopId as NSString).utf8String, -1, nil)

        var parentStation: String?
        if sqlite3_step(parentStmt) == SQLITE_ROW {
            parentStation = sqlite3_column_text(parentStmt, 0).map { String(cString: $0) }
        }

        guard let parent = parentStation, !parent.isEmpty else {
            return [stopId]
        }

        let siblingsSQL = "SELECT stop_id FROM stops WHERE parent_station = ?"
        var siblingsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, siblingsSQL, -1, &siblingsStmt, nil) == SQLITE_OK else {
            return [stopId]
        }
        defer { sqlite3_finalize(siblingsStmt) }
        sqlite3_bind_text(siblingsStmt, 1, (parent as NSString).utf8String, -1, nil)

        var ids: [String] = []
        while sqlite3_step(siblingsStmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(siblingsStmt, 0)))
        }

        return ids.isEmpty ? [stopId] : ids
    }

    /// Batched sibling lookup: given a set of stop IDs, returns a map of
    /// stopId → [all sibling stop IDs sharing the same parent_station].
    /// Uses 2 SQL queries regardless of how many stops are passed in.
    func trainSiblingMap(for stopIds: Set<String>) throws -> [String: [String]] {
        guard let db else { throw GTFSDBError.notReady }
        guard !stopIds.isEmpty else { return [:] }

        // Step 1: fetch parent_station for all requested stops
        let ph1 = stopIds.map { _ in "?" }.joined(separator: ",")
        let parentSQL = "SELECT stop_id, parent_station FROM stops WHERE stop_id IN (\(ph1))"
        var parentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, parentSQL, -1, &parentStmt, nil) == SQLITE_OK else {
            // fallback: identity map
            return Dictionary(uniqueKeysWithValues: stopIds.map { ($0, [$0]) })
        }
        defer { sqlite3_finalize(parentStmt) }
        var idx: Int32 = 1
        for id in stopIds {
            sqlite3_bind_text(parentStmt, idx, (id as NSString).utf8String, -1, nil)
            idx += 1
        }

        var stopToParent: [String: String] = [:]
        while sqlite3_step(parentStmt) == SQLITE_ROW {
            let sid = String(cString: sqlite3_column_text(parentStmt, 0))
            if let raw = sqlite3_column_text(parentStmt, 1) {
                let parent = String(cString: raw)
                if !parent.isEmpty { stopToParent[sid] = parent }
            }
        }

        let uniqueParents = Set(stopToParent.values)
        guard !uniqueParents.isEmpty else {
            return Dictionary(uniqueKeysWithValues: stopIds.map { ($0, [$0]) })
        }

        // Step 2: fetch all siblings for those parent stations
        let ph2 = uniqueParents.map { _ in "?" }.joined(separator: ",")
        let siblingsSQL = "SELECT stop_id, parent_station FROM stops WHERE parent_station IN (\(ph2))"
        var siblingsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, siblingsSQL, -1, &siblingsStmt, nil) == SQLITE_OK else {
            return Dictionary(uniqueKeysWithValues: stopIds.map { ($0, [$0]) })
        }
        defer { sqlite3_finalize(siblingsStmt) }
        idx = 1
        for parent in uniqueParents {
            sqlite3_bind_text(siblingsStmt, idx, (parent as NSString).utf8String, -1, nil)
            idx += 1
        }

        // Build parent → [sibling stop IDs]
        var parentToSiblings: [String: [String]] = [:]
        while sqlite3_step(siblingsStmt) == SQLITE_ROW {
            let sid = String(cString: sqlite3_column_text(siblingsStmt, 0))
            let parent = String(cString: sqlite3_column_text(siblingsStmt, 1))
            parentToSiblings[parent, default: []].append(sid)
        }

        // Map each original stop ID → its siblings
        var result: [String: [String]] = [:]
        for stopId in stopIds {
            if let parent = stopToParent[stopId], let siblings = parentToSiblings[parent] {
                result[stopId] = siblings
            } else {
                result[stopId] = [stopId]
            }
        }
        return result
    }

    func trainDepartures(
        forStopIds stopIds: [String],
        afterSeconds: Int,
        untilSeconds: Int
    ) throws -> [ScheduledDeparture] {
        guard let db else { throw GTFSDBError.notReady }
        guard !stopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let stopPlaceholders = stopIds.map { _ in "?" }.joined(separator: ",")
        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
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
              AND st.departure_seconds <= ?
              AND r.route_type = 2
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
        index += 1
        sqlite3_bind_int(stmt, index, Int32(untilSeconds))

        var results: [ScheduledDeparture] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let routeShortName: String
            if let raw = sqlite3_column_text(stmt, 8) {
                routeShortName = String(cString: raw)
            } else {
                routeShortName = "Train"
            }
            let routeLongName: String
            if let raw = sqlite3_column_text(stmt, 9) {
                routeLongName = String(cString: raw)
            } else {
                routeLongName = routeShortName
            }

            results.append(
                ScheduledDeparture(
                    tripId: String(cString: sqlite3_column_text(stmt, 0)),
                    stopId: String(cString: sqlite3_column_text(stmt, 1)),
                    departureTime: String(cString: sqlite3_column_text(stmt, 2)),
                    departureSeconds: Int(sqlite3_column_int(stmt, 3)),
                    stopSequence: Int(sqlite3_column_int(stmt, 4)),
                    routeId: String(cString: sqlite3_column_text(stmt, 5)),
                    tripHeadsign: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                    directionId: Int(sqlite3_column_int(stmt, 7)),
                    routeShortName: routeShortName,
                    routeLongName: routeLongName,
                    stopName: String(cString: sqlite3_column_text(stmt, 10))
                )
            )
        }

        return results
    }

    func trainTripPattern(tripId: String) throws -> [TripPatternStop] {
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
              AND r.route_type = 2
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
                    stopId: String(cString: sqlite3_column_text(stmt, 0)),
                    stopName: String(cString: sqlite3_column_text(stmt, 1)),
                    stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    stopLat: sqlite3_column_double(stmt, 3),
                    stopLon: sqlite3_column_double(stmt, 4),
                    arrivalTime: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    departureTime: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                    arrivalSeconds: Int(sqlite3_column_int(stmt, 7)),
                    departureSeconds: Int(sqlite3_column_int(stmt, 8)),
                    stopSequence: Int(sqlite3_column_int(stmt, 9))
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
              AND r.route_type = 3
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
                    stopId: String(cString: sqlite3_column_text(stmt, 0)),
                    stopName: String(cString: sqlite3_column_text(stmt, 1)),
                    stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    stopLat: sqlite3_column_double(stmt, 3),
                    stopLon: sqlite3_column_double(stmt, 4),
                    arrivalTime: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    departureTime: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                    arrivalSeconds: Int(sqlite3_column_int(stmt, 7)),
                    departureSeconds: Int(sqlite3_column_int(stmt, 8)),
                    stopSequence: Int(sqlite3_column_int(stmt, 9))
                )
            )
        }

        return results
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

    static func brisbaneMidnightSeconds() -> Int {
        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brisbane
        let now = Date()
        return calendar.component(.hour, from: now) * 3600
            + calendar.component(.minute, from: now) * 60
            + calendar.component(.second, from: now)
    }

    private func installBundledDatabase() async throws {
        guard let bundledURL = bundledDatabaseAssetURL() else {
            throw GTFSDBError.bundledAssetMissing
        }

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Installing Queensland bus data…",
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

        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brisbane
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = brisbane
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
                activeIds.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)

        let exceptionSQL = "SELECT service_id, exception_type FROM calendar_dates WHERE date = ?"
        if sqlite3_prepare_v2(db, exceptionSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let serviceId = String(cString: sqlite3_column_text(stmt, 0))
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
        exec("PRAGMA cache_size = -8000")
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
