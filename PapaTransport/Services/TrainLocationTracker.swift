import Combine
import CoreLocation
import Foundation

@MainActor
final class TrainLocationTracker: NSObject, ObservableObject {
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationDenied = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTracking = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 80
        manager.activityType = .fitness
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else {
            errorMessage = LocationError.unavailable.localizedDescription
            return
        }

        errorMessage = nil
        authorizationDenied = false

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        case .denied, .restricted:
            authorizationDenied = true
            errorMessage = LocationError.denied.localizedDescription
        @unknown default:
            manager.requestWhenInUseAuthorization()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isTracking = false
    }

    private func startUpdating() {
        manager.startUpdatingLocation()
        isTracking = true
    }
}

extension TrainLocationTracker: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                authorizationDenied = false
                errorMessage = nil
                startUpdating()
            case .denied, .restricted:
                stop()
                authorizationDenied = true
                errorMessage = LocationError.denied.localizedDescription
            default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let validLocations = locations.filter { $0.horizontalAccuracy >= 0 }
            guard let best = validLocations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else {
                errorMessage = LocationError.unavailable.localizedDescription
                return
            }

            currentLocation = best
            errorMessage = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
        }
    }
}
