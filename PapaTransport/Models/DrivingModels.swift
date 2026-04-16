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

        let departureDeadline = arrivalDate.addingTimeInterval(-Double(travelMinutes) * 60)
        let secondsLeft = departureDeadline.timeIntervalSince(now)
        return Int((secondsLeft / 60).rounded())
    }

    /// Human-readable countdown string, e.g. "Leave in 1h 47min", "Leave in 23 min", "Depart now", "23 min overdue".
    func countdownText(now: Date = Date()) -> String? {
        guard let mins = minutesUntilDeparture(now: now) else { return nil }
        if mins > 60 {
            let hours = mins / 60
            let remaining = mins % 60
            if remaining == 0 {
                return "Leave in \(hours)h"
            }
            return "Leave in \(hours)h \(remaining)min"
        } else if mins > 5 {
            return "Leave in \(mins) min"
        } else if mins >= -5 {
            return "Depart now"
        } else {
            return "\(abs(mins)) min overdue"
        }
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
