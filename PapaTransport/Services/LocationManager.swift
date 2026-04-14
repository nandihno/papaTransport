//
//  LocationManager.swift
//  myLatest
//

import CoreLocation
import Foundation

enum LocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Location access was denied."
        case .unavailable:
            return "Current device location is unavailable."
        }
    }
}

@MainActor
final class LocationManager: NSObject {
    private let clManager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Requests a one-shot location fix. Asks for permission first if needed.
    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationError.unavailable
        }

        return try await withCheckedThrowingContinuation { [weak self] (cont: CheckedContinuation<CLLocation, Error>) in
            guard let self else {
                cont.resume(throwing: LocationError.unavailable)
                return
            }

            if let existing = self.continuation {
                existing.resume(throwing: LocationError.unavailable)
                self.continuation = nil
            }

            self.continuation = cont

            switch clManager.authorizationStatus {
            case .notDetermined:
                clManager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                if let cached = self.bestAvailableLocation() {
                    self.deliver(.success(cached))
                } else {
                    clManager.requestLocation()
                }
            case .denied, .restricted:
                self.continuation = nil
                cont.resume(throwing: LocationError.denied)
            @unknown default:
                clManager.requestWhenInUseAuthorization()
            }
        }
    }

    private func bestAvailableLocation() -> CLLocation? {
        guard let location = clManager.location else { return nil }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        let isRecentEnough = age < 300
        let hasUsableAccuracy = location.horizontalAccuracy >= 0

        return (isRecentEnough && hasUsableAccuracy) ? location : nil
    }

    private func deliver(_ result: Result<CLLocation, Error>) {
        switch result {
        case .success(let loc):
            continuation?.resume(returning: loc)
        case .failure(let err):
            continuation?.resume(throwing: err)
        }
        continuation = nil
    }
}

extension LocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let validLocations = locations.filter { $0.horizontalAccuracy >= 0 }
        if let loc = validLocations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            deliver(.success(loc))
        } else {
            deliver(.failure(LocationError.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        deliver(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let cached = bestAvailableLocation() {
                deliver(.success(cached))
            } else {
                manager.requestLocation()
            }
        case .denied, .restricted:
            deliver(.failure(LocationError.denied))
        default:
            break
        }
    }
}
