//
//  TrainModels.swift
//  myLatest
//
//  Decodable structs for the two Metro Trains Melbourne endpoints:
//    • website_data.json  – line status, alerts, planned works
//    • departures.json    – real-time departure times per station
//

import Foundation

// MARK: - website_data.json
// The top-level object is keyed by line ID ("82", "84" …) but also contains
// non-line keys like "disruptions" whose values are arrays, not line objects.
// WebsiteDataResponse silently skips any key that can't be decoded as a line.
struct WebsiteDataResponse: Decodable {
    /// Each entry pairs the numeric line ID (the JSON key, e.g. "97") with its data.
    let lines: [(lineId: String, data: TrainLineAPIData)]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: _AnyKey.self)
        lines = container.allKeys.compactMap { key in
            guard let data = try? container.decode(TrainLineAPIData.self, forKey: key) else { return nil }
            return (lineId: key.stringValue, data: data)
        }
    }

    private struct _AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

struct TrainLineAPIData: Decodable {
    let lineName: String
    let plannedWorksList: [PlannedWorkAPIItem]
    let plannedWorks: [PlannedWorksAPIBody]
    let alertsPayload: AlertsAPIPayload   // polymorphic: String OR [AlertAPIItem]
    let extraServices: String?

    enum CodingKeys: String, CodingKey {
        case lineName         = "line_name"
        case plannedWorksList = "planned_works_list"
        case plannedWorks     = "planned_works"
        case alertsPayload    = "alerts"
        case extraServices    = "extra_services"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineName         = (try? c.decode(String.self, forKey: .lineName)) ?? ""
        plannedWorksList = (try? c.decode([PlannedWorkAPIItem].self, forKey: .plannedWorksList)) ?? []
        plannedWorks     = (try? c.decode([PlannedWorksAPIBody].self, forKey: .plannedWorks))   ?? []
        extraServices    = try? c.decode(String.self, forKey: .extraServices)

        // "alerts" is either a plain String ("Good service...") or an array of AlertAPIItem.
        if let str = try? c.decode(String.self, forKey: .alertsPayload) {
            alertsPayload = .message(str)
        } else if let arr = try? c.decode([AlertAPIItem].self, forKey: .alertsPayload) {
            alertsPayload = .items(arr)
        } else {
            alertsPayload = .message("Good service")
        }
    }
}

/// Polymorphic alerts field: either a good-service string or an array of live alerts.
enum AlertsAPIPayload: CustomStringConvertible {
    case message(String)
    case items([AlertAPIItem])

    var description: String {
        switch self {
        case .message(let s):  return ".message(\"\(s)\")"
        case .items(let arr):  return ".items(\(arr.count) alerts)"
        }
    }
}

struct AlertAPIItem: Decodable {
    let alertId: String
    let alertType: String           // "works" | "minor" | "major"
    let fromDate: String            // Unix timestamp string
    let toDate: String              // Unix timestamp string
    let additionalTravelTime: String?
    let disruptionDueTo: String?
    let alertText: String           // HTML

    enum CodingKeys: String, CodingKey {
        case alertId             = "alert_id"
        case alertType           = "alert_type"
        case fromDate            = "from_date"
        case toDate              = "to_date"
        case additionalTravelTime = "additional_travel_time"
        case disruptionDueTo     = "disruption_due_to"
        case alertText           = "alert_text"
    }
}

struct PlannedWorkAPIItem: Decodable {
    let id: Int
    let title: String
    let link: String
    let type: String
    let upcomingCurrent: String     // "Current" | "Upcoming"
    let startDateStr: String
    let endDateStr: String
    let affectedStations: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, link, type
        case upcomingCurrent  = "upcoming_current"
        case startDateStr     = "start_date_str"
        case endDateStr       = "end_date_str"
        case affectedStations = "affected_stations"
    }

    // Safe init — only `id` is hard-required; all other fields fall back to
    // sensible defaults so a partial entry never discards the whole works list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try  c.decode(Int.self,     forKey: .id)
        title            = (try? c.decode(String.self,  forKey: .title))            ?? ""
        link             = (try? c.decode(String.self,  forKey: .link))             ?? ""
        type             = (try? c.decode(String.self,  forKey: .type))             ?? ""
        upcomingCurrent  = (try? c.decode(String.self,  forKey: .upcomingCurrent))  ?? "Upcoming"
        startDateStr     = (try? c.decode(String.self,  forKey: .startDateStr))     ?? ""
        endDateStr       = (try? c.decode(String.self,  forKey: .endDateStr))       ?? ""
        affectedStations = (try? c.decode([String].self, forKey: .affectedStations)) ?? []
    }
}

struct PlannedWorksAPIBody: Decodable {
    let body: String
}

// MARK: - departures.json

struct DeparturesAPIResponse: Decodable {
    let entries: [DepartureAPIEntry]
}

// MARK: - op_timetable_<line_id>.json

struct TimetableAPIEntry: Decodable {
    let station: String
    let toCity: String              // "1" = inbound, "0" = outbound
    let timeSeconds: String         // seconds-since-midnight (string)
    let timeStr: String             // e.g. "6:20 AM"
    let isArrival: String           // "0" = departure, "1" = arrival
    let platform: String
    let date: String                // e.g. "2026-03-18"

    enum CodingKeys: String, CodingKey {
        case station
        case toCity      = "to_city"
        case timeSeconds = "time_seconds"
        case timeStr     = "time_str"
        case isArrival   = "is_arrival"
        case platform
        case date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        station    = try  c.decode(String.self, forKey: .station)
        toCity     = (try? c.decode(String.self, forKey: .toCity))     ?? "0"
        timeSeconds = (try? c.decode(String.self, forKey: .timeSeconds)) ?? "0"
        timeStr    = (try? c.decode(String.self, forKey: .timeStr))    ?? ""
        isArrival  = (try? c.decode(String.self, forKey: .isArrival))  ?? "0"
        platform   = (try? c.decode(String.self, forKey: .platform))   ?? ""
        date       = (try? c.decode(String.self, forKey: .date))       ?? ""
    }
}

struct DepartureAPIEntry: Decodable {
    let station: String
    let toCity: String              // "1" = inbound, "0" = outbound
    let timeStr: String             // scheduled departure time string
    let timeSeconds: String         // scheduled seconds-since-midnight (string)
    let platform: String            // scheduled platform (string)
    let isArrival: String           // "0" = departure, "1" = arrival
    let estimatedArrivalTimeStr: String
    let estimatedArrivalTimeSeconds: Int    // integer in API
    let estimatedDepartureTimeStr: String
    let estimatedDepartureTimeSeconds: Int  // integer in API
    let estimatedPlatform: String

    enum CodingKeys: String, CodingKey {
        case station
        case toCity                        = "to_city"
        case timeStr                       = "time_str"
        case timeSeconds                   = "time_seconds"
        case platform
        case isArrival                     = "is_arrival"
        case estimatedArrivalTimeStr       = "estimated_arrival_time_str"
        case estimatedArrivalTimeSeconds   = "estimated_arrival_time_seconds"
        case estimatedDepartureTimeStr     = "estimated_departure_time_str"
        case estimatedDepartureTimeSeconds = "estimated_departure_time_seconds"
        case estimatedPlatform             = "estimated_platform"
    }

    // Custom init — absent or null fields use safe defaults so a single
    // incomplete entry never kills the entire departures decode.
    // Only `station` is truly required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        station                       = try  c.decode(String.self, forKey: .station)
        toCity                        = (try? c.decode(String.self, forKey: .toCity))                        ?? "0"
        timeStr                       = (try? c.decode(String.self, forKey: .timeStr))                       ?? ""
        timeSeconds                   = (try? c.decode(String.self, forKey: .timeSeconds))                   ?? "0"
        platform                      = (try? c.decode(String.self, forKey: .platform))                      ?? ""
        isArrival                     = (try? c.decode(String.self, forKey: .isArrival))                     ?? "0"
        estimatedArrivalTimeStr       = (try? c.decode(String.self, forKey: .estimatedArrivalTimeStr))       ?? ""
        estimatedArrivalTimeSeconds   = (try? c.decode(Int.self,    forKey: .estimatedArrivalTimeSeconds))   ?? 0
        estimatedDepartureTimeStr     = (try? c.decode(String.self, forKey: .estimatedDepartureTimeStr))     ?? ""
        estimatedDepartureTimeSeconds = (try? c.decode(Int.self,    forKey: .estimatedDepartureTimeSeconds)) ?? 0
        estimatedPlatform             = (try? c.decode(String.self, forKey: .estimatedPlatform))             ?? ""
    }
}
