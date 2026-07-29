//
//  PTVStopIDResolver.swift
//  PapaTransport
//
//  Maps stored favourite stop ids (which come from the bundled GTFS database)
//  onto PTV stop ids.
//
//  The mapping is kept to one side rather than rewriting the favourites
//  themselves: the GTFS ids must stay intact so that turning the PTV feature
//  flag back off leaves favourites working.
//
//  Resolution is by proximity plus name match, because PTV exposes no
//  GTFS-id lookup for stops.
//

import Foundation
import CoreLocation

actor PTVStopIDResolver {
    static let shared = PTVStopIDResolver()

    /// Stored for ids that could not be matched, so a failed lookup is not
    /// retried on every board refresh.
    private static let unresolved = -1

    private var caches: [BusProvider: [String: Int]] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns original-stop-id → PTV-stop-id for everything that resolves.
    func ptvStopIds(
        for favourites: [FavouriteBusStop],
        routeType: PTVRouteType,
        provider: BusProvider
    ) async -> [String: Int] {
        var cache = loadCache(for: provider)
        var result: [String: Int] = [:]

        for favourite in favourites {
            if let cached = cache[favourite.stopId] {
                if cached != Self.unresolved { result[favourite.stopId] = cached }
                continue
            }

            let resolved = await lookup(favourite: favourite, routeType: routeType)
            cache[favourite.stopId] = resolved ?? Self.unresolved
            if let resolved { result[favourite.stopId] = resolved }
        }

        saveCache(cache, for: provider)
        return result
    }

    /// Cache-only lookup, for call sites that already have a resolved board.
    func cachedPTVStopId(forOriginalId originalId: String, provider: BusProvider) -> Int? {
        let cached = loadCache(for: provider)[originalId]
        return cached == Self.unresolved ? nil : cached
    }

    /// Forces re-resolution, e.g. after the bundled database is reinstalled.
    func clearCache(for provider: BusProvider) {
        caches[provider] = [:]
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(for: provider))
    }

    // MARK: - Resolution

    private func lookup(favourite: FavouriteBusStop, routeType: PTVRouteType) async -> Int? {
        // Stations sprawl further than a bus stop pole, so search wider.
        let radius = routeType == .train ? 800 : 250

        let candidates: [PTVStop]
        do {
            let response = try await PTVAPIClient.shared.get(
                PTVEndpoint.stopsNear(
                    latitude: favourite.latitude,
                    longitude: favourite.longitude,
                    routeTypes: [routeType],
                    maxDistanceMeters: radius
                ),
                as: PTVStopsResponse.self,
                cacheFor: 3600
            )
            candidates = response.stops
        } catch {
            print("⚠️ PTV stop-id resolution failed for \(favourite.stopName): \(error.localizedDescription)")
            return nil
        }

        guard !candidates.isEmpty else { return nil }

        let target = Self.normalise(favourite.stopName)

        if let exact = candidates.first(where: { Self.normalise($0.stopName) == target }) {
            return exact.stopId
        }

        let partial = candidates.filter {
            let name = Self.normalise($0.stopName)
            guard !name.isEmpty, !target.isEmpty else { return false }
            return name.hasPrefix(target) || target.hasPrefix(name)
                || name.contains(target) || target.contains(name)
        }
        if let best = partial.min(by: {
            ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude)
        }) {
            return best.stopId
        }

        // A single candidate inside a tight radius is unambiguous enough.
        if candidates.count == 1, (candidates[0].distanceMeters ?? .greatestFiniteMagnitude) <= 150 {
            return candidates[0].stopId
        }

        return nil
    }

    /// Strips the decoration that differs between GTFS and PTV naming —
    /// "Flinders Street Railway Station" vs "Flinders Street".
    private static func normalise(_ name: String) -> String {
        var value = name.lowercased()
        for noise in ["railway station", "train station", "station", "(vic)"] {
            value = value.replacingOccurrences(of: noise, with: " ")
        }
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(allowed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Persistence

    private static func defaultsKey(for provider: BusProvider) -> String {
        "ptvStopIdMap.\(provider.rawValue)"
    }

    private func loadCache(for provider: BusProvider) -> [String: Int] {
        if let cached = caches[provider] { return cached }
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey(for: provider)) as? [String: Int] ?? [:]
        caches[provider] = stored
        return stored
    }

    private func saveCache(_ cache: [String: Int], for provider: BusProvider) {
        caches[provider] = cache
        UserDefaults.standard.set(cache, forKey: Self.defaultsKey(for: provider))
    }
}
