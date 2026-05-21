//
//  CalendarDestinationService.swift
//  PapaTransport
//

import CoreLocation
import EventKit
import Foundation

@MainActor
final class CalendarDestinationService {
    static let shared = CalendarDestinationService()

    private let eventStore = EKEventStore()
    private let geocoder = CLGeocoder()
    private var geocodeCache: [String: CLLocationCoordinate2D] = [:]
    private var geocodeCacheDay: Date?

    private init() {}

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Requests calendar access from the user. Safe to call repeatedly.
    @discardableResult
    func requestAccess() async -> EKAuthorizationStatus {
        switch authorizationStatus {
        case .notDetermined:
            do {
                if #available(iOS 17.0, *) {
                    _ = try await eventStore.requestFullAccessToEvents()
                } else {
                    _ = try await eventStore.requestAccess(to: .event)
                }
            } catch {
                return authorizationStatus
            }
            return authorizationStatus
        default:
            return authorizationStatus
        }
    }

    /// Returns destinations for today's calendar events whose start is in the future
    /// and that have a non-empty, geocodable location.
    func fetchUpcomingTodayDestinations() async -> [DrivingDestination] {
        let status = authorizationStatus
        let isAuthorized: Bool
        if #available(iOS 17.0, *) {
            isAuthorized = (status == .fullAccess || status == .authorized)
        } else {
            isAuthorized = (status == .authorized)
        }
        guard isAuthorized else { return [] }

        let calendar = Calendar.current
        let now = Date()
        guard let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) else {
            return []
        }

        resetCacheIfDayChanged(now: now)

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endOfDay,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        var destinations: [DrivingDestination] = []
        for event in events {
            guard let dest = await destination(for: event, now: now) else { continue }
            destinations.append(dest)
        }
        return destinations.sorted { lhs, rhs in
            arrivalDate(for: lhs) < arrivalDate(for: rhs)
        }
    }

    // MARK: - Private

    private func destination(for event: EKEvent, now: Date) async -> DrivingDestination? {
        guard event.isAllDay == false else { return nil }
        let location = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return nil }
        guard let startDate = event.startDate, startDate > now else { return nil }

        if let status = event.participantStatus(for: event.attendees ?? []),
           status == .declined { return nil }

        guard let coordinate = await coordinate(for: location, event: event) else { return nil }

        let comps = Calendar.current.dateComponents([.hour, .minute], from: startDate)
        let eventID = event.eventIdentifier ?? UUID().uuidString
        let stableID = uuid(forSeed: eventID)

        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return DrivingDestination(
            id: stableID,
            name: location,
            address: location,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            title: title.isEmpty ? nil : title,
            targetArrivalHour: comps.hour,
            targetArrivalMinute: comps.minute,
            source: .calendar(eventID: eventID)
        )
    }

    private func coordinate(for location: String, event: EKEvent) async -> CLLocationCoordinate2D? {
        if let structured = event.structuredLocation?.geoLocation {
            return structured.coordinate
        }

        if let parsed = parseLatLng(from: location) {
            return parsed
        }

        let key = location.lowercased()
        if let cached = geocodeCache[key] {
            return cached
        }

        do {
            let placemarks = try await geocoder.geocodeAddressString(location)
            if let coord = placemarks.first?.location?.coordinate {
                geocodeCache[key] = coord
                return coord
            }
        } catch {
            // Drop silently — unparseable locations don't surface as destinations.
        }
        return nil
    }

    private func parseLatLng(from string: String) -> CLLocationCoordinate2D? {
        let parts = string.split(separator: ",")
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lng = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lng)
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private func resetCacheIfDayChanged(now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        if geocodeCacheDay != day {
            geocodeCache.removeAll(keepingCapacity: true)
            geocodeCacheDay = day
        }
    }

    private func arrivalDate(for destination: DrivingDestination) -> Date {
        guard let h = destination.targetArrivalHour, let m = destination.targetArrivalMinute else {
            return .distantFuture
        }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps) ?? .distantFuture
    }

    /// Build a stable UUID from a string seed so calendar destinations keep the same identity across refreshes.
    private func uuid(forSeed seed: String) -> UUID {
        var bytes = Array(seed.utf8)
        while bytes.count < 16 { bytes.append(0) }
        let prefix = Array(bytes.prefix(16))
        let tuple: uuid_t = (
            prefix[0], prefix[1], prefix[2], prefix[3],
            prefix[4], prefix[5], prefix[6], prefix[7],
            prefix[8], prefix[9], prefix[10], prefix[11],
            prefix[12], prefix[13], prefix[14], prefix[15]
        )
        return UUID(uuid: tuple)
    }
}

private extension EKEvent {
    func participantStatus(for attendees: [EKParticipant]) -> EKParticipantStatus? {
        attendees.first(where: { $0.isCurrentUser })?.participantStatus
    }
}
