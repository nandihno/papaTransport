//
//  DrivingModels.swift
//  PapaTransport
//

import Foundation

// MARK: - DrivingProvider

enum DrivingProvider: String {
    case apple
    case google
}

// MARK: - DrivingTimeEstimate

struct DrivingTimeEstimate: Identifiable {
    let destination: DrivingDestination
    let travelMinutes: Int?
    let delayMinutes: Int?
    let advisory: String?
    let hasDelay: Bool
    let errorMessage: String?

    var id: UUID { destination.id }
    var isAvailable: Bool { travelMinutes != nil && errorMessage == nil }

    static func unavailable(destination: DrivingDestination, message: String) -> DrivingTimeEstimate {
        DrivingTimeEstimate(
            destination: destination,
            travelMinutes: nil,
            delayMinutes: nil,
            advisory: nil,
            hasDelay: false,
            errorMessage: message
        )
    }

    // MARK: - Arrival countdown

    /// Minutes until the user must depart to reach the destination by their target arrival time.
    /// Negative means they are already overdue.
    /// Returns nil if no arrival target is set or travel time is unknown.
    func minutesUntilDeparture(now: Date = Date()) -> Int? {
        guard let departureDeadline = departureDeadline(now: now) else { return nil }
        let secondsLeft = departureDeadline.timeIntervalSince(now)
        return Int((secondsLeft / 60).rounded())
    }

    /// The absolute time the user needs to leave to reach the destination by their target arrival time.
    func departureDeadline(now: Date = Date()) -> Date? {
        guard let travelMinutes, let hour = destination.targetArrivalHour,
              let minute = destination.targetArrivalMinute else { return nil }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var arrivalDate = calendar.date(from: components) else { return nil }

        // If the target time has already passed today, assume they mean tomorrow
        if arrivalDate < now {
            arrivalDate = calendar.date(byAdding: .day, value: 1, to: arrivalDate) ?? arrivalDate
        }

        return arrivalDate.addingTimeInterval(-Double(travelMinutes) * 60)
    }

    /// Human-readable departure string, e.g. "Leave at 6:30 pm" or "Depart now".
    func countdownText(now: Date = Date()) -> String? {
        guard let departureDeadline = departureDeadline(now: now),
              let mins = minutesUntilDeparture(now: now) else { return nil }

        if mins >= -5, mins <= 5 {
            return "Depart now"
        }

        let time = departureDeadline.formatted(date: .omitted, time: .shortened)
        return mins < -5 ? "Leave time passed" : "Leave at \(time)"
    }

    /// Colour for the countdown pill based on urgency.
    var countdownUrgency: CountdownUrgency {
        guard let mins = minutesUntilDeparture() else { return .none }
        if mins > 30 { return .comfortable }
        if mins > 10 { return .soon }
        return .urgent
    }
}

enum CountdownUrgency {
    case none, comfortable, soon, urgent
}
