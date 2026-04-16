//
//  DrivingDestination.swift
//  PapaTransport
//

import CoreLocation
import Foundation

struct DrivingDestination: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    var title: String?
    /// Hour component (0–23) of the user's target arrival time, if set.
    var targetArrivalHour: Int?
    /// Minute component (0–59) of the user's target arrival time, if set.
    var targetArrivalMinute: Int?

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        title: String? = nil,
        targetArrivalHour: Int? = nil,
        targetArrivalMinute: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.title = title
        self.targetArrivalHour = targetArrivalHour
        self.targetArrivalMinute = targetArrivalMinute
    }

    /// Returns the user-provided title if set, otherwise the resolved name.
    var displayName: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return name
    }

    /// Returns the subtitle to show beneath the display name.
    var displaySubtitle: String { address }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether a target arrival time has been configured.
    var hasArrivalTarget: Bool {
        targetArrivalHour != nil && targetArrivalMinute != nil
    }

    /// A display string for the arrival target, e.g. "Arrive by 10:15 PM".
    var arrivalTargetDisplay: String? {
        guard let hour = targetArrivalHour, let minute = targetArrivalMinute else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "Arrive by \(formatter.string(from: date))"
    }

    /// Returns a copy with the given title applied.
    func withTitle(_ title: String) -> DrivingDestination {
        var copy = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = trimmed.isEmpty ? nil : trimmed
        return copy
    }
}
