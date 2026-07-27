//
//  PlanLiteService.swift
//  PapaTransport
//
//  Trip estimates via MapKit, with no bundled timetable data.
//
//  Apple exposes a transit *ETA* but not a transit *itinerary*: calling
//  `MKDirections.calculate()` with `.transit` fails with
//  `MKError.directionsNotFound`, so there are no legs, route numbers or
//  polylines to draw. Walking and driving do return full routes.
//
//  The itinerary itself is therefore handed off to the Apple Maps app.
//

import Foundation
import MapKit

enum PlanLiteMode: String, CaseIterable, Identifiable {
    case transit
    case walking
    case driving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transit: return "Public transport"
        case .walking: return "Walk"
        case .driving: return "Drive"
        }
    }

    var symbolName: String {
        switch self {
        case .transit: return "tram.fill"
        case .walking: return "figure.walk"
        case .driving: return "car.fill"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .transit: return .transit
        case .walking: return .walking
        case .driving: return .automobile
        }
    }

    var launchOptionsMode: String {
        switch self {
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        }
    }
}

nonisolated struct PlanLiteLeg: Identifiable {
    let mode: PlanLiteMode
    let travelTime: TimeInterval
    let distanceMeters: CLLocationDistance
    /// Empty for transit — Apple does not expose the route, only the ETA.
    let coordinates: [CLLocationCoordinate2D]

    var id: String { mode.rawValue }
    var isDrawable: Bool { coordinates.count > 1 }
}

nonisolated struct PlanLiteResult {
    let legs: [PlanLiteLeg]

    func leg(for mode: PlanLiteMode) -> PlanLiteLeg? {
        legs.first { $0.mode == mode }
    }
}

final class PlanLiteService {
    static let shared = PlanLiteService()
    private init() {}

    /// Estimates all three modes concurrently. Modes Apple cannot answer for a
    /// given pair are simply absent from the result.
    func plan(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> PlanLiteResult {
        let legs = await withTaskGroup(of: PlanLiteLeg?.self) { group in
            for mode in PlanLiteMode.allCases {
                group.addTask {
                    await Self.leg(mode: mode, from: origin, to: destination)
                }
            }
            var collected: [PlanLiteLeg] = []
            for await leg in group {
                if let leg { collected.append(leg) }
            }
            return collected
        }

        let order = PlanLiteMode.allCases
        return PlanLiteResult(
            legs: legs.sorted {
                (order.firstIndex(of: $0.mode) ?? 0) < (order.firstIndex(of: $1.mode) ?? 0)
            }
        )
    }

    @MainActor
    func openInAppleMaps(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: PlanLiteMode
    ) {
        let source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        source.name = "Start"
        let target = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        target.name = "Destination"

        MKMapItem.openMaps(
            with: [source, target],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launchOptionsMode]
        )
    }

    private static func leg(
        mode: PlanLiteMode,
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> PlanLiteLeg? {
        func request() -> MKDirections.Request {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = mode.transportType
            return request
        }

        // Only walking and driving can return a drawable route; asking for a
        // transit route always fails, so skip straight to the ETA.
        if mode != .transit,
           let route = try? await MKDirections(request: request()).calculate().routes.first {
            return PlanLiteLeg(
                mode: mode,
                travelTime: route.expectedTravelTime,
                distanceMeters: route.distance,
                coordinates: route.polyline.coordinateList
            )
        }

        guard let eta = try? await MKDirections(request: request()).calculateETA() else {
            return nil
        }
        return PlanLiteLeg(
            mode: mode,
            travelTime: eta.expectedTravelTime,
            distanceMeters: eta.distance,
            coordinates: []
        )
    }
}

extension MKMultiPoint {
    var coordinateList: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
