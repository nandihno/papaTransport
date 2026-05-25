import CoreLocation
import Foundation
import SQLite3

actor VictorianBusGTFSDatabase {
    static let shared = VictorianBusGTFSDatabase()

    private var db: OpaquePointer?
    private var isImported = false

    private let bundledDatabaseFileName = "gtfs_victorian_bus"
    private let bundledDatabaseExtension = "sqlite3"
    private let bundledDatabaseSubdirectory = "db/transport/victoria"

    private var dbPath: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("gtfs_victorian_bus.sqlite3").path
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

    func routePlannerStopCandidates(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 650,
        limit: Int = 8
    ) throws -> [(stop: GTFSStop, distanceMeters: Double)] {
        guard let db else { throw GTFSDBError.notReady }

        let latDelta = radiusMeters / 111_000.0
        let lonDelta = radiusMeters / (111_000.0 * cos(latitude * .pi / 180.0))
        let sql = """
            SELECT stop_id, stop_name, stop_code, stop_lat, stop_lon, location_type, parent_station
            FROM stops
            WHERE route_type IN (3, 701)
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

        let selectedLocation = CLLocation(latitude: latitude, longitude: longitude)
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
            let distance = selectedLocation.distance(from: stopLocation)
            if distance <= radiusMeters {
                results.append((stop, distance))
            }
        }

        return Array(results.sorted { $0.1 < $1.1 }.prefix(limit))
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

    func directRoutePlanCandidates(
        originStopIds: [String],
        destinationStopIds: [String],
        afterSeconds: Int,
        limit: Int = 12
    ) throws -> [DirectRoutePlanCandidate] {
        guard let db else { throw GTFSDBError.notReady }
        guard !originStopIds.isEmpty, !destinationStopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let originPlaceholders = originStopIds.map { _ in "?" }.joined(separator: ",")
        let destinationPlaceholders = destinationStopIds.map { _ in "?" }.joined(separator: ",")
        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT origin_st.trip_id,
                   t.route_id, r.route_short_name, r.route_long_name,
                   t.trip_headsign, t.direction_id, r.route_type,
                   origin_st.stop_id, origin_s.stop_name, origin_s.stop_code,
                   origin_s.stop_lat, origin_s.stop_lon,
                   IFNULL(origin_st.departure_time, origin_st.arrival_time) AS origin_time,
                   IFNULL(origin_st.departure_seconds, origin_st.arrival_seconds) AS origin_seconds,
                   origin_st.stop_sequence,
                   destination_st.stop_id, destination_s.stop_name, destination_s.stop_code,
                   destination_s.stop_lat, destination_s.stop_lon,
                   IFNULL(destination_st.arrival_time, destination_st.departure_time) AS destination_time,
                   IFNULL(destination_st.arrival_seconds, destination_st.departure_seconds) AS destination_seconds,
                   destination_st.stop_sequence
            FROM stop_times origin_st
            JOIN stop_times destination_st
              ON destination_st.trip_id = origin_st.trip_id
             AND destination_st.stop_sequence > origin_st.stop_sequence
            JOIN trips t ON t.trip_id = origin_st.trip_id
            JOIN routes r ON r.route_id = t.route_id
            JOIN stops origin_s ON origin_s.stop_id = origin_st.stop_id
            JOIN stops destination_s ON destination_s.stop_id = destination_st.stop_id
            WHERE origin_st.stop_id IN (\(originPlaceholders))
              AND destination_st.stop_id IN (\(destinationPlaceholders))
              AND t.service_id IN (\(servicePlaceholders))
              AND r.route_type IN (3, 701)
              AND IFNULL(origin_st.departure_seconds, origin_st.arrival_seconds) >= ?
            ORDER BY origin_seconds ASC, destination_seconds ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        for stopId in originStopIds {
            sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil)
            index += 1
        }
        for stopId in destinationStopIds {
            sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil)
            index += 1
        }
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(afterSeconds))
        index += 1
        sqlite3_bind_int(stmt, index, Int32(limit))

        var results: [DirectRoutePlanCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                DirectRoutePlanCandidate(
                    tripId: String(cString: sqlite3_column_text(stmt, 0)),
                    routeId: String(cString: sqlite3_column_text(stmt, 1)),
                    routeShortName: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    routeLongName: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    tripHeadsign: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    directionId: Int(sqlite3_column_int(stmt, 5)),
                    routeType: Int(sqlite3_column_int(stmt, 6)),
                    originStopId: String(cString: sqlite3_column_text(stmt, 7)),
                    originStopName: String(cString: sqlite3_column_text(stmt, 8)),
                    originStopCode: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                    originLat: sqlite3_column_double(stmt, 10),
                    originLon: sqlite3_column_double(stmt, 11),
                    originTime: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
                    originSeconds: Int(sqlite3_column_int(stmt, 13)),
                    originSequence: Int(sqlite3_column_int(stmt, 14)),
                    destinationStopId: String(cString: sqlite3_column_text(stmt, 15)),
                    destinationStopName: String(cString: sqlite3_column_text(stmt, 16)),
                    destinationStopCode: sqlite3_column_text(stmt, 17).map { String(cString: $0) },
                    destinationLat: sqlite3_column_double(stmt, 18),
                    destinationLon: sqlite3_column_double(stmt, 19),
                    destinationTime: sqlite3_column_text(stmt, 20).map { String(cString: $0) },
                    destinationSeconds: Int(sqlite3_column_int(stmt, 21)),
                    destinationSequence: Int(sqlite3_column_int(stmt, 22))
                )
            )
        }

        return results
    }

    func routePlanTripStops(
        tripId: String,
        fromSequence: Int,
        toSequence: Int
    ) throws -> [RoutePlanTripPatternStop] {
        guard let db else { throw GTFSDBError.notReady }

        let sql = """
            SELECT st.stop_id, s.stop_name, s.stop_code, s.stop_lat, s.stop_lon,
                   IFNULL(st.arrival_time, st.departure_time) AS scheduled_time,
                   IFNULL(st.arrival_seconds, st.departure_seconds) AS scheduled_seconds,
                   st.stop_sequence
            FROM stop_times st
            JOIN stops s ON st.stop_id = s.stop_id
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE st.trip_id = ?
              AND st.stop_sequence BETWEEN ? AND ?
              AND r.route_type IN (3, 701)
            ORDER BY st.stop_sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(fromSequence))
        sqlite3_bind_int(stmt, 3, Int32(toSequence))

        var results: [RoutePlanTripPatternStop] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                RoutePlanTripPatternStop(
                    stopId: String(cString: sqlite3_column_text(stmt, 0)),
                    stopName: String(cString: sqlite3_column_text(stmt, 1)),
                    stopCode: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    stopLat: sqlite3_column_double(stmt, 3),
                    stopLon: sqlite3_column_double(stmt, 4),
                    scheduledTime: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    scheduledSeconds: Int(sqlite3_column_int(stmt, 6)),
                    stopSequence: Int(sqlite3_column_int(stmt, 7))
                )
            )
        }

        return results
    }

    func routePlanShapeCoordinates(
        tripId: String,
        fromSequence: Int,
        toSequence: Int
    ) throws -> [CLLocationCoordinate2D] {
        guard let db else { throw GTFSDBError.notReady }

        let shapeBoundsSQL = """
            SELECT t.shape_id, origin_st.shape_dist_traveled, destination_st.shape_dist_traveled
            FROM trips t
            JOIN stop_times origin_st
              ON origin_st.trip_id = t.trip_id
             AND origin_st.stop_sequence = ?
            JOIN stop_times destination_st
              ON destination_st.trip_id = t.trip_id
             AND destination_st.stop_sequence = ?
            WHERE t.trip_id = ?
        """

        var boundsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, shapeBoundsSQL, -1, &boundsStmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(boundsStmt) }

        sqlite3_bind_int(boundsStmt, 1, Int32(fromSequence))
        sqlite3_bind_int(boundsStmt, 2, Int32(toSequence))
        sqlite3_bind_text(boundsStmt, 3, (tripId as NSString).utf8String, -1, nil)

        guard sqlite3_step(boundsStmt) == SQLITE_ROW,
              let shapeIdText = sqlite3_column_text(boundsStmt, 0),
              sqlite3_column_type(boundsStmt, 1) != SQLITE_NULL,
              sqlite3_column_type(boundsStmt, 2) != SQLITE_NULL else {
            return []
        }

        let shapeId = String(cString: shapeIdText)
        let fromDistance = sqlite3_column_double(boundsStmt, 1)
        let toDistance = sqlite3_column_double(boundsStmt, 2)
        let minDistance = min(fromDistance, toDistance)
        let maxDistance = max(fromDistance, toDistance)

        guard !shapeId.isEmpty, maxDistance > minDistance else { return [] }

        let shapeSQL = """
            SELECT shape_pt_lat, shape_pt_lon
            FROM shapes
            WHERE shape_id = ?
              AND shape_dist_traveled BETWEEN ? AND ?
            ORDER BY shape_pt_sequence ASC
        """

        var shapeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, shapeSQL, -1, &shapeStmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(shapeStmt) }

        sqlite3_bind_text(shapeStmt, 1, (shapeId as NSString).utf8String, -1, nil)
        sqlite3_bind_double(shapeStmt, 2, minDistance)
        sqlite3_bind_double(shapeStmt, 3, maxDistance)

        var coordinates: [CLLocationCoordinate2D] = []
        while sqlite3_step(shapeStmt) == SQLITE_ROW {
            coordinates.append(
                CLLocationCoordinate2D(
                    latitude: sqlite3_column_double(shapeStmt, 0),
                    longitude: sqlite3_column_double(shapeStmt, 1)
                )
            )
        }

        return coordinates
    }

    func reachableRoutePlanLegCandidates(
        originStopIds: [String],
        afterSeconds: Int,
        horizonSeconds: Int = 45 * 60,
        limit: Int = 80
    ) throws -> [DirectRoutePlanCandidate] {
        guard let db else { throw GTFSDBError.notReady }
        guard !originStopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let originPlaceholders = originStopIds.map { _ in "?" }.joined(separator: ",")
        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT origin_st.trip_id,
                   t.route_id, r.route_short_name, r.route_long_name,
                   t.trip_headsign, t.direction_id, r.route_type,
                   origin_st.stop_id, origin_s.stop_name, origin_s.stop_code,
                   origin_s.stop_lat, origin_s.stop_lon,
                   IFNULL(origin_st.departure_time, origin_st.arrival_time) AS origin_time,
                   IFNULL(origin_st.departure_seconds, origin_st.arrival_seconds) AS origin_seconds,
                   origin_st.stop_sequence,
                   destination_st.stop_id, destination_s.stop_name, destination_s.stop_code,
                   destination_s.stop_lat, destination_s.stop_lon,
                   IFNULL(destination_st.arrival_time, destination_st.departure_time) AS destination_time,
                   IFNULL(destination_st.arrival_seconds, destination_st.departure_seconds) AS destination_seconds,
                   destination_st.stop_sequence
            FROM stop_times origin_st
            JOIN stop_times destination_st
              ON destination_st.trip_id = origin_st.trip_id
             AND destination_st.stop_sequence > origin_st.stop_sequence
            JOIN trips t ON t.trip_id = origin_st.trip_id
            JOIN routes r ON r.route_id = t.route_id
            JOIN stops origin_s ON origin_s.stop_id = origin_st.stop_id
            JOIN stops destination_s ON destination_s.stop_id = destination_st.stop_id
            WHERE origin_st.stop_id IN (\(originPlaceholders))
              AND t.service_id IN (\(servicePlaceholders))
              AND r.route_type IN (3, 701)
              AND IFNULL(origin_st.departure_seconds, origin_st.arrival_seconds) BETWEEN ? AND ?
            ORDER BY origin_seconds ASC, destination_seconds ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        for stopId in originStopIds {
            sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil)
            index += 1
        }
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(afterSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(afterSeconds + horizonSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(limit))

        var results: [DirectRoutePlanCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                DirectRoutePlanCandidate(
                    tripId: String(cString: sqlite3_column_text(stmt, 0)),
                    routeId: String(cString: sqlite3_column_text(stmt, 1)),
                    routeShortName: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    routeLongName: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    tripHeadsign: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    directionId: Int(sqlite3_column_int(stmt, 5)),
                    routeType: Int(sqlite3_column_int(stmt, 6)),
                    originStopId: String(cString: sqlite3_column_text(stmt, 7)),
                    originStopName: String(cString: sqlite3_column_text(stmt, 8)),
                    originStopCode: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                    originLat: sqlite3_column_double(stmt, 10),
                    originLon: sqlite3_column_double(stmt, 11),
                    originTime: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
                    originSeconds: Int(sqlite3_column_int(stmt, 13)),
                    originSequence: Int(sqlite3_column_int(stmt, 14)),
                    destinationStopId: String(cString: sqlite3_column_text(stmt, 15)),
                    destinationStopName: String(cString: sqlite3_column_text(stmt, 16)),
                    destinationStopCode: sqlite3_column_text(stmt, 17).map { String(cString: $0) },
                    destinationLat: sqlite3_column_double(stmt, 18),
                    destinationLon: sqlite3_column_double(stmt, 19),
                    destinationTime: sqlite3_column_text(stmt, 20).map { String(cString: $0) },
                    destinationSeconds: Int(sqlite3_column_int(stmt, 21)),
                    destinationSequence: Int(sqlite3_column_int(stmt, 22))
                )
            )
        }

        return results
    }

    func oneTransferRoutePlanCandidates(
        originStopIds: [String],
        destinationStopIds: [String],
        afterSeconds: Int,
        minimumTransferSeconds: Int = 5 * 60,
        maximumTransferSeconds: Int = 45 * 60,
        horizonSeconds: Int = 2 * 60 * 60,
        limit: Int = 12
    ) throws -> [OneTransferRoutePlanCandidate] {
        guard let db else { throw GTFSDBError.notReady }
        guard !originStopIds.isEmpty, !destinationStopIds.isEmpty else { return [] }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let originPlaceholders = originStopIds.map { _ in "?" }.joined(separator: ",")
        let destinationPlaceholders = destinationStopIds.map { _ in "?" }.joined(separator: ",")
        let firstServicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let secondServicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT first_origin.trip_id,
                   first_t.route_id, first_r.route_short_name, first_r.route_long_name,
                   first_t.trip_headsign, first_t.direction_id, first_r.route_type,
                   first_origin.stop_id, origin_s.stop_name, origin_s.stop_code,
                   origin_s.stop_lat, origin_s.stop_lon,
                   IFNULL(first_origin.departure_time, first_origin.arrival_time) AS first_origin_time,
                   IFNULL(first_origin.departure_seconds, first_origin.arrival_seconds) AS first_origin_seconds,
                   first_origin.stop_sequence,
                   first_transfer.stop_id, transfer_s.stop_name, transfer_s.stop_code,
                   transfer_s.stop_lat, transfer_s.stop_lon,
                   IFNULL(first_transfer.arrival_time, first_transfer.departure_time) AS first_transfer_time,
                   IFNULL(first_transfer.arrival_seconds, first_transfer.departure_seconds) AS first_transfer_seconds,
                   first_transfer.stop_sequence,
                   second_transfer.trip_id,
                   second_t.route_id, second_r.route_short_name, second_r.route_long_name,
                   second_t.trip_headsign, second_t.direction_id, second_r.route_type,
                   second_transfer.stop_id, transfer_s.stop_name, transfer_s.stop_code,
                   transfer_s.stop_lat, transfer_s.stop_lon,
                   IFNULL(second_transfer.departure_time, second_transfer.arrival_time) AS second_transfer_time,
                   IFNULL(second_transfer.departure_seconds, second_transfer.arrival_seconds) AS second_transfer_seconds,
                   second_transfer.stop_sequence,
                   destination_st.stop_id, destination_s.stop_name, destination_s.stop_code,
                   destination_s.stop_lat, destination_s.stop_lon,
                   IFNULL(destination_st.arrival_time, destination_st.departure_time) AS destination_time,
                   IFNULL(destination_st.arrival_seconds, destination_st.departure_seconds) AS destination_seconds,
                   destination_st.stop_sequence
            FROM stop_times first_origin
            JOIN stop_times first_transfer
              ON first_transfer.trip_id = first_origin.trip_id
             AND first_transfer.stop_sequence > first_origin.stop_sequence
            JOIN stop_times second_transfer
              ON second_transfer.stop_id = first_transfer.stop_id
             AND IFNULL(second_transfer.departure_seconds, second_transfer.arrival_seconds)
                 BETWEEN IFNULL(first_transfer.arrival_seconds, first_transfer.departure_seconds) + ?
                     AND IFNULL(first_transfer.arrival_seconds, first_transfer.departure_seconds) + ?
            JOIN stop_times destination_st
              ON destination_st.trip_id = second_transfer.trip_id
             AND destination_st.stop_sequence > second_transfer.stop_sequence
            JOIN trips first_t ON first_t.trip_id = first_origin.trip_id
            JOIN trips second_t ON second_t.trip_id = second_transfer.trip_id
            JOIN routes first_r ON first_r.route_id = first_t.route_id
            JOIN routes second_r ON second_r.route_id = second_t.route_id
            JOIN stops origin_s ON origin_s.stop_id = first_origin.stop_id
            JOIN stops transfer_s ON transfer_s.stop_id = first_transfer.stop_id
            JOIN stops destination_s ON destination_s.stop_id = destination_st.stop_id
            WHERE first_origin.stop_id IN (\(originPlaceholders))
              AND destination_st.stop_id IN (\(destinationPlaceholders))
              AND first_t.service_id IN (\(firstServicePlaceholders))
              AND second_t.service_id IN (\(secondServicePlaceholders))
              AND first_r.route_type IN (3, 701)
              AND second_r.route_type IN (3, 701)
              AND first_origin.trip_id != second_transfer.trip_id
              AND IFNULL(first_origin.departure_seconds, first_origin.arrival_seconds) BETWEEN ? AND ?
            ORDER BY first_origin_seconds ASC, destination_seconds ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_int(stmt, index, Int32(minimumTransferSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(maximumTransferSeconds)); index += 1
        for stopId in originStopIds {
            sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil)
            index += 1
        }
        for stopId in destinationStopIds {
            sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil)
            index += 1
        }
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(afterSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(afterSeconds + horizonSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(limit))

        var results: [OneTransferRoutePlanCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let firstLeg = DirectRoutePlanCandidate(
                tripId: String(cString: sqlite3_column_text(stmt, 0)),
                routeId: String(cString: sqlite3_column_text(stmt, 1)),
                routeShortName: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                routeLongName: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                tripHeadsign: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                directionId: Int(sqlite3_column_int(stmt, 5)),
                routeType: Int(sqlite3_column_int(stmt, 6)),
                originStopId: String(cString: sqlite3_column_text(stmt, 7)),
                originStopName: String(cString: sqlite3_column_text(stmt, 8)),
                originStopCode: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                originLat: sqlite3_column_double(stmt, 10),
                originLon: sqlite3_column_double(stmt, 11),
                originTime: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
                originSeconds: Int(sqlite3_column_int(stmt, 13)),
                originSequence: Int(sqlite3_column_int(stmt, 14)),
                destinationStopId: String(cString: sqlite3_column_text(stmt, 15)),
                destinationStopName: String(cString: sqlite3_column_text(stmt, 16)),
                destinationStopCode: sqlite3_column_text(stmt, 17).map { String(cString: $0) },
                destinationLat: sqlite3_column_double(stmt, 18),
                destinationLon: sqlite3_column_double(stmt, 19),
                destinationTime: sqlite3_column_text(stmt, 20).map { String(cString: $0) },
                destinationSeconds: Int(sqlite3_column_int(stmt, 21)),
                destinationSequence: Int(sqlite3_column_int(stmt, 22))
            )
            let secondLeg = DirectRoutePlanCandidate(
                tripId: String(cString: sqlite3_column_text(stmt, 23)),
                routeId: String(cString: sqlite3_column_text(stmt, 24)),
                routeShortName: sqlite3_column_text(stmt, 25).map { String(cString: $0) } ?? "",
                routeLongName: sqlite3_column_text(stmt, 26).map { String(cString: $0) } ?? "",
                tripHeadsign: sqlite3_column_text(stmt, 27).map { String(cString: $0) },
                directionId: Int(sqlite3_column_int(stmt, 28)),
                routeType: Int(sqlite3_column_int(stmt, 29)),
                originStopId: String(cString: sqlite3_column_text(stmt, 30)),
                originStopName: String(cString: sqlite3_column_text(stmt, 31)),
                originStopCode: sqlite3_column_text(stmt, 32).map { String(cString: $0) },
                originLat: sqlite3_column_double(stmt, 33),
                originLon: sqlite3_column_double(stmt, 34),
                originTime: sqlite3_column_text(stmt, 35).map { String(cString: $0) },
                originSeconds: Int(sqlite3_column_int(stmt, 36)),
                originSequence: Int(sqlite3_column_int(stmt, 37)),
                destinationStopId: String(cString: sqlite3_column_text(stmt, 38)),
                destinationStopName: String(cString: sqlite3_column_text(stmt, 39)),
                destinationStopCode: sqlite3_column_text(stmt, 40).map { String(cString: $0) },
                destinationLat: sqlite3_column_double(stmt, 41),
                destinationLon: sqlite3_column_double(stmt, 42),
                destinationTime: sqlite3_column_text(stmt, 43).map { String(cString: $0) },
                destinationSeconds: Int(sqlite3_column_int(stmt, 44)),
                destinationSequence: Int(sqlite3_column_int(stmt, 45))
            )
            results.append(OneTransferRoutePlanCandidate(firstLeg: firstLeg, secondLeg: secondLeg))
        }

        return results
    }

    func routesAtStopToday(stopId: String) throws -> [BusRouteAtStop] {
        guard let db else { throw GTFSDBError.notReady }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT DISTINCT r.route_id, r.route_short_name, r.route_long_name,
                            t.direction_id, t.trip_headsign
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE st.stop_id = ?
              AND t.service_id IN (\(servicePlaceholders))
              AND r.route_type = 3
            ORDER BY r.route_short_name COLLATE NOCASE ASC, t.direction_id ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (stopId as NSString).utf8String, -1, nil)
        var index: Int32 = 2
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }

        var results: [BusRouteAtStop] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                BusRouteAtStop(
                    routeId: String(cString: sqlite3_column_text(stmt, 0)),
                    routeShortName: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    routeLongName: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    directionId: Int(sqlite3_column_int(stmt, 3)),
                    tripHeadsign: sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                )
            )
        }

        return results
    }

    func activeTripsThroughStop(
        routeId: String,
        directionId: Int,
        stopId: String,
        aroundSeconds: Int,
        windowSeconds: Int = 25 * 60,
        limit: Int = 20
    ) throws -> [ActiveTripCandidate] {
        guard let db else { throw GTFSDBError.notReady }

        let activeServiceIds = try todayActiveServiceIds()
        guard !activeServiceIds.isEmpty else { return [] }

        let servicePlaceholders = activeServiceIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT t.trip_id, t.route_id, r.route_short_name, r.route_long_name,
                   t.trip_headsign, t.direction_id,
                   (SELECT MIN(IFNULL(st2.departure_seconds, st2.arrival_seconds))
                      FROM stop_times st2 WHERE st2.trip_id = t.trip_id) AS first_seconds,
                   (SELECT MAX(IFNULL(st2.arrival_seconds, st2.departure_seconds))
                      FROM stop_times st2 WHERE st2.trip_id = t.trip_id) AS last_seconds,
                   IFNULL(st.departure_seconds, st.arrival_seconds) AS boarding_seconds
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE st.stop_id = ?
              AND t.route_id = ?
              AND t.direction_id = ?
              AND t.service_id IN (\(servicePlaceholders))
              AND r.route_type = 3
              AND IFNULL(st.departure_seconds, st.arrival_seconds) BETWEEN ? AND ?
            ORDER BY ABS(IFNULL(st.departure_seconds, st.arrival_seconds) - ?) ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        sqlite3_bind_text(stmt, index, (stopId as NSString).utf8String, -1, nil); index += 1
        sqlite3_bind_text(stmt, index, (routeId as NSString).utf8String, -1, nil); index += 1
        sqlite3_bind_int(stmt, index, Int32(directionId)); index += 1
        for serviceId in activeServiceIds {
            sqlite3_bind_text(stmt, index, (serviceId as NSString).utf8String, -1, nil)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(aroundSeconds - windowSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(aroundSeconds + windowSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(aroundSeconds)); index += 1
        sqlite3_bind_int(stmt, index, Int32(limit))

        var results: [ActiveTripCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(
                ActiveTripCandidate(
                    tripId: String(cString: sqlite3_column_text(stmt, 0)),
                    routeId: String(cString: sqlite3_column_text(stmt, 1)),
                    routeShortName: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    routeLongName: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    tripHeadsign: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    directionId: Int(sqlite3_column_int(stmt, 5)),
                    firstSeconds: Int(sqlite3_column_int(stmt, 6)),
                    lastSeconds: Int(sqlite3_column_int(stmt, 7)),
                    boardingSeconds: Int(sqlite3_column_int(stmt, 8))
                )
            )
        }

        return results
    }

    struct BusRouteAtStop {
        let routeId: String
        let routeShortName: String
        let routeLongName: String
        let directionId: Int
        let tripHeadsign: String?
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
        let boardingSeconds: Int
    }

    struct DirectRoutePlanCandidate {
        let tripId: String
        let routeId: String
        let routeShortName: String
        let routeLongName: String
        let tripHeadsign: String?
        let directionId: Int
        let routeType: Int
        let originStopId: String
        let originStopName: String
        let originStopCode: String?
        let originLat: Double
        let originLon: Double
        let originTime: String?
        let originSeconds: Int
        let originSequence: Int
        let destinationStopId: String
        let destinationStopName: String
        let destinationStopCode: String?
        let destinationLat: Double
        let destinationLon: Double
        let destinationTime: String?
        let destinationSeconds: Int
        let destinationSequence: Int
    }

    struct OneTransferRoutePlanCandidate {
        let firstLeg: DirectRoutePlanCandidate
        let secondLeg: DirectRoutePlanCandidate
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

    struct RoutePlanTripPatternStop {
        let stopId: String
        let stopName: String
        let stopCode: String?
        let stopLat: Double
        let stopLon: Double
        let scheduledTime: String?
        let scheduledSeconds: Int
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

    private func installBundledDatabase() async throws {
        guard let bundledURL = bundledDatabaseAssetURL() else {
            throw GTFSDBError.bundledAssetMissing
        }

        await MainActor.run {
            GTFSDownloadProgress.shared.update(
                stage: "Installing Victorian bus data…",
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
        let stopCount = queryCount("SELECT COUNT(*) FROM stops")
        let shapeCount = queryCount("SELECT COUNT(*) FROM shapes")
        if stopCount > 0 && shapeCount > 0 {
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
        exec("PRAGMA cache_size = -12000")
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
