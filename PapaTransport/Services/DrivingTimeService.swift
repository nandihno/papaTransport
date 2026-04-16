//
//  DrivingTimeService.swift
//  PapaTransport
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class DrivingTimeService {
    static let shared = DrivingTimeService()

    private let locationManager = LocationManager()

    private static let googleEndpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    private init() {}

    func fetchDrivingTimes(provider: DrivingProvider, googleApiKey: String) async throws -> [DrivingTimeEstimate] {
        let destinations = DrivingDestinationStore.shared.all
        guard !destinations.isEmpty else { return [] }

        if provider == .google, googleApiKey.isEmpty {
            return destinations.map {
                .unavailable(destination: $0, message: "Google Maps API key not set. Add it in Settings.")
            }
        }

        let sourceLocation = try await locationManager.currentLocation()

        return await withTaskGroup(of: (Int, DrivingTimeEstimate).self) { group in
            for (index, destination) in destinations.enumerated() {
                group.addTask {
                    let estimate: DrivingTimeEstimate
                    switch provider {
                    case .apple:
                        estimate = await Self.fetchAppleEstimate(from: sourceLocation, to: destination)
                    case .google:
                        estimate = await Self.fetchGoogleEstimate(from: sourceLocation, to: destination, apiKey: googleApiKey)
                    }
                    return (index, estimate)
                }
            }

            var indexedResults: [(Int, DrivingTimeEstimate)] = []
            for await item in group {
                indexedResults.append(item)
            }

            return indexedResults
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    // MARK: - Apple Maps

    private static func fetchAppleEstimate(
        from sourceLocation: CLLocation,
        to destination: DrivingDestination
    ) async -> DrivingTimeEstimate {
        do {
            let request = MKDirections.Request()
            request.source = MKMapItem(location: sourceLocation, address: nil)
            request.destination = MKMapItem(
                location: CLLocation(latitude: destination.coordinate.latitude,
                                     longitude: destination.coordinate.longitude),
                address: nil
            )
            request.transportType = .automobile
            request.departureDate = Date()

            let response = try await calculateDirections(for: request)
            guard let route = response.routes.first else {
                return .unavailable(destination: destination, message: "No driving route found.")
            }

            let notices = route.advisoryNotices
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let delayMinutes = parseDelayMinutes(from: notices)
            let hasDelay = (delayMinutes ?? 0) > 0 || noticesSuggestDelay(notices)

            return DrivingTimeEstimate(
                destination: destination,
                travelMinutes: roundedMinutes(from: route.expectedTravelTime),
                delayMinutes: delayMinutes,
                advisory: notices.first,
                hasDelay: hasDelay,
                errorMessage: nil
            )
        } catch is CancellationError {
            return .unavailable(destination: destination, message: "Route lookup cancelled.")
        } catch {
            return .unavailable(destination: destination, message: error.localizedDescription)
        }
    }

    private static func calculateDirections(for request: MKDirections.Request) async throws -> MKDirections.Response {
        let directions = MKDirections(request: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                directions.calculate { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: LocationError.unavailable)
                    }
                }
            }
        } onCancel: {
            directions.cancel()
        }
    }

    private static func roundedMinutes(from travelTime: TimeInterval) -> Int {
        max(1, Int((travelTime / 60).rounded()))
    }

    private static func parseDelayMinutes(from notices: [String]) -> Int? {
        let patterns = [
            #"\b(\d+)\s*(?:min|mins|minute|minutes)\b"#,
            #"\bdelay(?:ed|s)?\s*(?:up to\s*)?(\d+)\s*(?:min|mins|minute|minutes)\b"#
        ]

        for notice in notices {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }

                let range = NSRange(notice.startIndex..<notice.endIndex, in: notice)
                guard
                    let match = regex.firstMatch(in: notice, options: [], range: range),
                    match.numberOfRanges > 1,
                    let minuteRange = Range(match.range(at: 1), in: notice),
                    let minutes = Int(notice[minuteRange])
                else { continue }

                return minutes
            }
        }

        return nil
    }

    private static func noticesSuggestDelay(_ notices: [String]) -> Bool {
        let delayKeywords = [
            "delay", "traffic", "congestion", "roadworks",
            "road work", "incident", "accident", "closure", "slow"
        ]

        return notices.contains { notice in
            let lowercased = notice.lowercased()
            return delayKeywords.contains(where: lowercased.contains)
        }
    }

    // MARK: - Google Routes API

    private static func fetchGoogleEstimate(
        from sourceLocation: CLLocation,
        to destination: DrivingDestination,
        apiKey: String
    ) async -> DrivingTimeEstimate {
        do {
            let body = GoogleRoutesRequest(
                origin: .init(latitude: sourceLocation.coordinate.latitude,
                              longitude: sourceLocation.coordinate.longitude),
                destination: .init(latitude: destination.latitude,
                                   longitude: destination.longitude)
            )

            var request = URLRequest(url: googleEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
            request.setValue(
                "routes.duration,routes.staticDuration,routes.distanceMeters,routes.travelAdvisory",
                forHTTPHeaderField: "X-Goog-FieldMask"
            )
            request.httpBody = try JSONEncoder().encode(body)

            let (data, httpResponse) = try await URLSession.shared.data(for: request)

            if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                return .unavailable(destination: destination, message: "Google API error: \(message)")
            }

            let decoded = try JSONDecoder().decode(GoogleRoutesResponse.self, from: data)
            guard let route = decoded.routes?.first else {
                return .unavailable(destination: destination, message: "No driving route found.")
            }

            let durationSec = parseDurationSeconds(route.duration)
            let staticSec = parseDurationSeconds(route.staticDuration)
            let travelMinutes = max(1, Int((Double(durationSec) / 60.0).rounded()))

            var delayMinutes: Int? = nil
            var hasDelay = false
            if durationSec > 0, staticSec > 0, durationSec > staticSec {
                let delaySec = durationSec - staticSec
                let delayMins = Int((Double(delaySec) / 60.0).rounded())
                if delayMins >= 1 {
                    delayMinutes = delayMins
                    hasDelay = true
                }
            }

            let advisory = route.travelAdvisory.flatMap { adv -> String? in
                guard let warnings = adv.speedReadingIntervals, !warnings.isEmpty else { return nil }
                let slowCount = warnings.filter { $0.speed == "SLOW" || $0.speed == "TRAFFIC_JAM" }.count
                if slowCount == 0 { return nil }
                return "\(slowCount) slow/congested segment\(slowCount == 1 ? "" : "s") on route"
            }

            if advisory != nil { hasDelay = true }

            return DrivingTimeEstimate(
                destination: destination,
                travelMinutes: travelMinutes,
                delayMinutes: delayMinutes,
                advisory: advisory,
                hasDelay: hasDelay,
                errorMessage: nil
            )
        } catch is CancellationError {
            return .unavailable(destination: destination, message: "Route lookup cancelled.")
        } catch {
            return .unavailable(destination: destination, message: error.localizedDescription)
        }
    }

    /// Parses Google's duration string format "123s" → 123
    private static func parseDurationSeconds(_ value: String?) -> Int {
        guard let value, value.hasSuffix("s"),
              let secs = Int(value.dropLast()) else { return 0 }
        return secs
    }
}

// MARK: - Google Routes API Models

private struct GoogleRoutesRequest: Encodable {
    let origin: Waypoint
    let destination: Waypoint
    let travelMode = "DRIVE"
    let routingPreference = "TRAFFIC_AWARE_OPTIMAL"

    struct Waypoint: Encodable {
        let location: LatLngWrapper

        init(latitude: Double, longitude: Double) {
            self.location = LatLngWrapper(latLng: LatLng(latitude: latitude, longitude: longitude))
        }
    }

    struct LatLngWrapper: Encodable {
        let latLng: LatLng
    }

    struct LatLng: Encodable {
        let latitude: Double
        let longitude: Double
    }
}

private struct GoogleRoutesResponse: Decodable {
    let routes: [Route]?

    struct Route: Decodable {
        let duration: String?
        let staticDuration: String?
        let distanceMeters: Int?
        let travelAdvisory: TravelAdvisory?
    }

    struct TravelAdvisory: Decodable {
        let speedReadingIntervals: [SpeedReading]?
    }

    struct SpeedReading: Decodable {
        let speed: String?
    }
}
