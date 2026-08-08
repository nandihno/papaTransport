//
//  PTVAPIClient.swift
//  PapaTransport
//
//  Signed transport for the PTV Timetable API v3.
//
//  PTV publishes no rate limits, and the API is per-stop rather than batched,
//  so a single board refresh can fan out to a dozen calls. This client
//  therefore caps concurrency, caches responses briefly, and backs off after
//  a throttling response rather than hammering the endpoint.
//

import Foundation

actor PTVAPIClient {
    static let shared = PTVAPIClient()

    enum PTVError: LocalizedError {
        case notConfigured
        case invalidPath(String)
        case http(status: Int, body: String?)
        case rateLimited(retryAfter: TimeInterval)
        case transport(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "PTV credentials are not configured. Run scripts/generate_ptv_credentials.swift and paste the output into PTVCredentials.swift."
            case .invalidPath(let path):
                return "Could not build a valid PTV URL for \(path)."
            case .http(let status, let body):
                if status == 403 {
                    return "PTV rejected the request (403). The signature or devid may be wrong, or the key has been revoked."
                }
                return "PTV request failed with HTTP \(status).\(body.map { " \($0)" } ?? "")"
            case .rateLimited(let retryAfter):
                return "PTV is rate limiting requests. Retrying in \(Int(retryAfter))s."
            case .transport(let message):
                return "Could not reach PTV: \(message)"
            case .decoding(let message):
                return "Could not read the PTV response: \(message)"
            }
        }
    }

    private let baseURL = "https://timetableapi.ptv.vic.gov.au"
    private let defaultCacheTTL: TimeInterval = 25
    private let limiter = PTVRequestLimiter(limit: 5)

    private var cache: [String: (expiresAt: Date, data: Data)] = [:]
    private var backoffUntil: Date?
    private var consecutiveThrottles = 0

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(raw, strategy: .iso8601) { return date }
            if let date = try? Date(raw, strategy: .iso8601.time(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised PTV date: \(raw)")
            )
        }
        return decoder
    }()

    // MARK: - Public API

    /// Signs, sends and decodes a PTV request. `path` starts with "/v3/".
    func get<T: Decodable>(_ path: String, as type: T.Type, cacheFor ttl: TimeInterval? = nil) async throws -> T {
        let data = try await data(for: path, cacheFor: ttl)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PTVError.decoding(error.localizedDescription)
        }
    }

    /// Phase 1 smoke test: proves credentials and signing work end to end.
    func verifyConnection() async throws -> [PTVRouteTypeDescriptor] {
        let response = try await get(PTVEndpoint.routeTypes, as: PTVRouteTypesResponse.self, cacheFor: 3600)
        return response.routeTypes
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Transport

    private func data(for path: String, cacheFor ttl: TimeInterval?) async throws -> Data {
        guard PTVCredentials.isConfigured else { throw PTVError.notConfigured }

        if let cached = cache[path], cached.expiresAt > Date() {
            return cached.data
        }

        if let backoffUntil, backoffUntil > Date() {
            throw PTVError.rateLimited(retryAfter: backoffUntil.timeIntervalSinceNow)
        }

        let signed = PTVSignature.signedPath(
            for: path,
            devid: PTVCredentials.devid,
            apiKey: PTVCredentials.apiKey
        )
        guard let url = URL(string: baseURL + signed) else {
            throw PTVError.invalidPath(path)
        }

        await limiter.acquire()
        defer { Task { await limiter.release() } }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw PTVError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PTVError.transport("Malformed response")
        }

        switch http.statusCode {
        case 200...299:
            consecutiveThrottles = 0
            backoffUntil = nil
            cache[path] = (Date().addingTimeInterval(ttl ?? defaultCacheTTL), data)
            pruneCacheIfNeeded()
            return data

        case 429, 503:
            consecutiveThrottles += 1
            let delay = min(pow(2, Double(consecutiveThrottles)), 60)
            backoffUntil = Date().addingTimeInterval(delay)
            throw PTVError.rateLimited(retryAfter: delay)

        default:
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PTVError.http(status: http.statusCode, body: body?.isEmpty == false ? body : nil)
        }
    }

    private func pruneCacheIfNeeded() {
        guard cache.count > 200 else { return }
        let now = Date()
        cache = cache.filter { $0.value.expiresAt > now }
    }
}

// MARK: - Concurrency Gate

/// Caps in-flight PTV requests. On release the slot is handed straight to the
/// next waiter rather than decremented, so the active count cannot drift.
private actor PTVRequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Endpoints

nonisolated enum PTVEndpoint {
    static let routeTypes = "/v3/route_types"

    static func departures(
        routeType: PTVRouteType,
        stopId: Int,
        maxResults: Int = 5,
        expand: [String] = ["Route", "Direction", "Run", "Disruption"]
    ) -> String {
        "/v3/departures/route_type/\(routeType.rawValue)/stop/\(stopId)"
            + "?max_results=\(maxResults)"
            + expand.map { "&expand=\($0)" }.joined()
    }

    static func stopsNear(
        latitude: Double,
        longitude: Double,
        routeTypes: [PTVRouteType],
        maxDistanceMeters: Int = 300
    ) -> String {
        let types = routeTypes.map { "&route_types=\($0.rawValue)" }.joined()
        return "/v3/stops/location/\(latitude),\(longitude)?max_distance=\(maxDistanceMeters)" + types
    }

    /// Bus run references contain hyphens ("35-234--1-Sat11-235237"). Those are
    /// RFC 3986 unreserved characters — percent-encoding them changes the string
    /// that gets signed and PTV rejects the request with 403.
    private static let runRefAllowed = CharacterSet(charactersIn: "-._~").union(.alphanumerics)

    /// `expand=VehicleDescriptor` is required for `vehicle_descriptor` to be
    /// populated — without it the field comes back nil even on runs that have
    /// one (verified 2026-07-31).
    static func pattern(runRef: String, routeType: PTVRouteType) -> String {
        let encoded = runRef.addingPercentEncoding(withAllowedCharacters: runRefAllowed) ?? runRef
        return "/v3/pattern/run/\(encoded)/route_type/\(routeType.rawValue)"
            + "?expand=Stop&expand=Run&expand=VehicleDescriptor"
    }

    static func disruptionsForStop(_ stopId: Int) -> String {
        "/v3/disruptions/stop/\(stopId)"
    }

    static func routes(routeType: PTVRouteType) -> String {
        "/v3/routes?route_types=\(routeType.rawValue)"
    }
}
