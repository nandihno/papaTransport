//
//  PTVStopCache.swift
//  PapaTransport
//
//  Persistent entity-and-coverage cache for PTV stop discovery.
//

import CoreLocation
import Foundation

/// The static part of a PTV stop response. This type is deliberately
/// nonisolated because it crosses the `PTVStopCache` actor boundary.
nonisolated struct PTVCachedStop: Codable, Sendable {
    let stopId: Int
    let stopName: String
    let stopLandmark: String?
    let latitude: Double
    let longitude: Double
    let routeType: Int
}

/// A quantised discovery request. The radius bucket prevents a small query
/// from being treated as coverage for a later, larger query at the same point.
nonisolated struct PTVStopCacheTileKey: Codable, Hashable, Sendable {
    static let tileSizeDegrees = 0.005

    let latitudeIndex: Int
    let longitudeIndex: Int
    let radiusBucketMeters: Int
    let routeTypes: [Int]

    init(
        latitude: Double,
        longitude: Double,
        radiusMeters: Int,
        routeTypes: [PTVRouteType]
    ) {
        latitudeIndex = Int(floor(latitude / Self.tileSizeDegrees))
        longitudeIndex = Int(floor(longitude / Self.tileSizeDegrees))
        radiusBucketMeters = Self.radiusBucket(for: radiusMeters)
        self.routeTypes = Array(Set(routeTypes.map(\.rawValue))).sorted()
    }

    private static func radiusBucket(for radiusMeters: Int) -> Int {
        let minimum = max(300, radiusMeters)
        let bucketSize = 250
        return ((minimum + bucketSize - 1) / bucketSize) * bucketSize
    }
}

private nonisolated struct PTVStopCacheCoverage: Codable, Sendable {
    let key: PTVStopCacheTileKey
    let lastSweptAt: Date
    let containedStops: Bool

    func isFresh(at date: Date) -> Bool {
        let ttl: TimeInterval = containedStops ? 7 * 24 * 60 * 60 : 60 * 60
        return date.timeIntervalSince(lastSweptAt) < ttl
    }
}

private nonisolated struct PTVStopCacheFile: Codable, Sendable {
    let stops: [PTVCachedStop]
    let coverage: [PTVStopCacheCoverage]
}

nonisolated struct PTVStopCacheLookup: Sendable {
    let stops: [PTVStop]
    let missingCoverage: [PTVStopCacheTileKey]
}

nonisolated struct PTVStopCacheStatistics: Sendable {
    let stopCount: Int
    let tileCount: Int
    let oldestSweepDate: Date?

    static let empty = PTVStopCacheStatistics(
        stopCount: 0,
        tileCount: 0,
        oldestSweepDate: nil
    )
}

/// Disk-backed cache for static Victorian PTV stop identity.
///
/// This must remain an actor. With the target's default MainActor isolation,
/// JSON encoding and decoding a large stop set would otherwise run on the UI
/// actor and recreate the freeze this project has already experienced.
actor PTVStopCache {
    static let shared = PTVStopCache()

    nonisolated static func boundingBox(
        latitude: Double,
        longitude: Double,
        radiusMeters: Int
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let latitudeDelta = Double(radiusMeters) / 111_000
        let longitudeScale = max(abs(cos(latitude * .pi / 180)), 0.1)
        let longitudeDelta = Double(radiusMeters) / (111_000 * longitudeScale)
        return (
            latitude - latitudeDelta,
            latitude + latitudeDelta,
            longitude - longitudeDelta,
            longitude + longitudeDelta
        )
    }

    private var stops: [Int: PTVCachedStop] = [:]
    private var coverage: [PTVStopCacheTileKey: PTVStopCacheCoverage] = [:]
    private var hasLoaded = false

    private let fileURL: URL?

    private init() {
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Timetables", isDirectory: true)
            .appendingPathComponent("stop-cache.json", isDirectory: false)
    }

    // MARK: - Public API

    func lookup(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        referenceLatitude: Double,
        referenceLongitude: Double,
        routeTypes: [PTVRouteType],
        coverageKeys: [PTVStopCacheTileKey],
        maxDistanceMeters: Int? = nil
    ) -> PTVStopCacheLookup {
        loadIfNeeded()

        let now = Date()
        let missingCoverage = coverageKeys.filter {
            guard let entry = coverage[$0] else { return true }
            return !entry.isFresh(at: now)
        }

        let requestedTypes = Set(routeTypes.map(\.rawValue))
        let reference = CLLocation(latitude: referenceLatitude, longitude: referenceLongitude)
        let cachedStops = stops.values.compactMap { stop -> PTVStop? in
            let distance = reference.distance(
                from: CLLocation(latitude: stop.latitude, longitude: stop.longitude)
            )
            guard stop.latitude >= minLatitude,
                  stop.latitude <= maxLatitude,
                  stop.longitude >= minLongitude,
                  stop.longitude <= maxLongitude,
                  Self.supports(routeType: stop.routeType, requestedTypes: requestedTypes),
                  maxDistanceMeters.map({ distance <= Double($0) }) ?? true
            else { return nil }

            return PTVStop(
                stopId: stop.stopId,
                stopName: stop.stopName,
                stopLandmark: stop.stopLandmark,
                routeType: stop.routeType,
                latitude: stop.latitude,
                longitude: stop.longitude,
                distanceMeters: distance
            )
        }

        return PTVStopCacheLookup(
            stops: cachedStops,
            missingCoverage: missingCoverage
        )
    }

    func store(
        _ fetchedStops: [PTVStop],
        swept coverageKeys: [PTVStopCacheTileKey] = [],
        at date: Date = Date()
    ) {
        loadIfNeeded()

        for stop in fetchedStops where stop.stopId > 0 {
            let record = PTVCachedStop(
                stopId: stop.stopId,
                stopName: stop.stopName,
                stopLandmark: stop.stopLandmark,
                latitude: stop.latitude,
                longitude: stop.longitude,
                routeType: stop.routeType
            )

            // A shared metro/V-Line station has one PTV id. Prefer the metro
            // representation when both responses describe the same identity.
            if let existing = stops[stop.stopId],
               existing.routeType != PTVRouteType.vline.rawValue,
               stop.routeType == PTVRouteType.vline.rawValue {
                continue
            }
            stops[stop.stopId] = record
        }

        for key in coverageKeys {
            coverage[key] = PTVStopCacheCoverage(
                key: key,
                lastSweptAt: date,
                containedStops: !fetchedStops.isEmpty
            )
        }

        persist()
    }

    func statistics() -> PTVStopCacheStatistics {
        loadIfNeeded()
        return PTVStopCacheStatistics(
            stopCount: stops.count,
            tileCount: coverage.count,
            oldestSweepDate: coverage.values.map(\.lastSweptAt).min()
        )
    }

    func clear() {
        stops.removeAll()
        coverage.removeAll()
        hasLoaded = true

        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true

        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(PTVStopCacheFile.self, from: data)
        else { return }

        stops = Dictionary(uniqueKeysWithValues: stored.stops.map { ($0.stopId, $0) })
        coverage = Dictionary(uniqueKeysWithValues: stored.coverage.map { ($0.key, $0) })
    }

    private func persist() {
        guard let fileURL else { return }

        do {
            var directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)

            let file = PTVStopCacheFile(
                stops: Array(stops.values),
                coverage: Array(coverage.values)
            )
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ PTV stop cache could not be saved: \(error.localizedDescription)")
        }
    }

    private static func supports(routeType: Int, requestedTypes: Set<Int>) -> Bool {
        requestedTypes.contains(routeType)
            || (requestedTypes.contains(PTVRouteType.train.rawValue)
                && routeType == PTVRouteType.vline.rawValue)
    }
}
