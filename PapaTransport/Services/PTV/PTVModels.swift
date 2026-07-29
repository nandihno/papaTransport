//
//  PTVModels.swift
//  PapaTransport
//
//  Codable DTOs for the PTV Timetable API v3.
//
//  Only `departures` has been verified against a live response; the remaining
//  shapes decode defensively so an unexpected or renamed field degrades to a
//  default rather than failing the whole response. Use
//  scripts/dump_ptv_shapes.sh to capture real payloads and tighten these.
//

import Foundation

// MARK: - Route Types

nonisolated enum PTVRouteType: Int, CaseIterable, Sendable {
    case train    = 0
    case tram     = 1
    case bus      = 2
    case vline    = 3
    case nightBus = 4

    var displayName: String {
        switch self {
        case .train:    return "Train"
        case .tram:     return "Tram"
        case .bus:      return "Bus"
        case .vline:    return "V/Line"
        case .nightBus: return "Night Bus"
        }
    }
}

// MARK: - Envelope

/// `/v3/departures/...` and `/v3/patterns/...` share this envelope. The
/// `expand` dictionaries are keyed by the stringified object id and arrive
/// empty unless the request asked for them.
nonisolated struct PTVDeparturesResponse: Decodable {
    let departures: [PTVDeparture]
    let stops: [String: PTVStop]
    let routes: [String: PTVRoute]
    let runs: [String: PTVRun]
    let directions: [String: PTVDirection]
    let disruptions: [String: PTVDisruption]

    private enum CodingKeys: String, CodingKey {
        case departures, stops, routes, runs, directions, disruptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        departures = (try? c.decodeIfPresent([PTVDeparture].self, forKey: .departures)) ?? []
        stops      = (try? c.decodeIfPresent([String: PTVStop].self, forKey: .stops)) ?? [:]
        routes     = (try? c.decodeIfPresent([String: PTVRoute].self, forKey: .routes)) ?? [:]
        runs       = (try? c.decodeIfPresent([String: PTVRun].self, forKey: .runs)) ?? [:]
        directions = (try? c.decodeIfPresent([String: PTVDirection].self, forKey: .directions)) ?? [:]

        // `disruptions` is an object keyed by id on /v3/departures but a plain
        // array on /v3/pattern. Normalise both to a dictionary.
        if let keyed = try? c.decodeIfPresent([String: PTVDisruption].self, forKey: .disruptions) {
            disruptions = keyed
        } else if let listed = try? c.decodeIfPresent([PTVDisruption].self, forKey: .disruptions) {
            var byId: [String: PTVDisruption] = [:]
            for disruption in listed { byId[String(disruption.disruptionId)] = disruption }
            disruptions = byId
        } else {
            disruptions = [:]
        }
    }
}

// MARK: - Departure

nonisolated struct PTVDeparture: Decodable, Identifiable {
    let stopId: Int
    let routeId: Int
    let runId: Int
    let runRef: String
    let directionId: Int
    let disruptionIds: [Int]
    let scheduledDeparture: Date?
    let estimatedDeparture: Date?
    let atPlatform: Bool
    let platformNumber: String?
    let flags: String
    /// Populated (1-based) on `/v3/pattern` responses; always 0 on
    /// `/v3/departures`, so stop position requires the pattern call.
    let departureSequence: Int
    let departureNote: String?
    /// Express runs list the stops they pass. Element shape is unconfirmed —
    /// every captured sample was a stopping-all-stations run — so this decodes
    /// leniently and falls back to empty.
    let skippedStops: [PTVStop]

    var id: String { "\(runRef)-\(stopId)-\(scheduledDeparture?.timeIntervalSince1970 ?? 0)" }

    /// Real-time estimate when present, otherwise the timetable.
    var effectiveDeparture: Date? { estimatedDeparture ?? scheduledDeparture }

    /// Positive = running late. `nil` when there is no real-time estimate.
    var delaySeconds: Int? {
        guard let estimatedDeparture, let scheduledDeparture else { return nil }
        return Int(estimatedDeparture.timeIntervalSince(scheduledDeparture))
    }

    private enum CodingKeys: String, CodingKey {
        case stopId = "stop_id"
        case routeId = "route_id"
        case runId = "run_id"
        case runRef = "run_ref"
        case directionId = "direction_id"
        case disruptionIds = "disruption_ids"
        case scheduledDeparture = "scheduled_departure_utc"
        case estimatedDeparture = "estimated_departure_utc"
        case atPlatform = "at_platform"
        case platformNumber = "platform_number"
        case flags
        case departureSequence = "departure_sequence"
        case departureNote = "departure_note"
        case skippedStops = "skipped_stops"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopId             = (try? c.decodeIfPresent(Int.self, forKey: .stopId)) ?? 0
        routeId            = (try? c.decodeIfPresent(Int.self, forKey: .routeId)) ?? 0
        runId              = (try? c.decodeIfPresent(Int.self, forKey: .runId)) ?? 0
        runRef             = (try? c.decodeIfPresent(String.self, forKey: .runRef)) ?? ""
        directionId        = (try? c.decodeIfPresent(Int.self, forKey: .directionId)) ?? 0
        disruptionIds      = (try? c.decodeIfPresent([Int].self, forKey: .disruptionIds)) ?? []
        scheduledDeparture = (try? c.decodeIfPresent(Date.self, forKey: .scheduledDeparture)) ?? nil
        estimatedDeparture = (try? c.decodeIfPresent(Date.self, forKey: .estimatedDeparture)) ?? nil
        atPlatform         = (try? c.decodeIfPresent(Bool.self, forKey: .atPlatform)) ?? false
        platformNumber     = (try? c.decodeIfPresent(String.self, forKey: .platformNumber)) ?? nil
        flags              = (try? c.decodeIfPresent(String.self, forKey: .flags)) ?? ""
        departureSequence  = (try? c.decodeIfPresent(Int.self, forKey: .departureSequence)) ?? 0
        departureNote      = (try? c.decodeIfPresent(String.self, forKey: .departureNote)) ?? nil
        skippedStops       = (try? c.decodeIfPresent([PTVStop].self, forKey: .skippedStops)) ?? []
    }
}

// MARK: - Stop

nonisolated struct PTVStopsResponse: Decodable {
    let stops: [PTVStop]

    private enum CodingKeys: String, CodingKey { case stops }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stops = (try? c.decodeIfPresent([PTVStop].self, forKey: .stops)) ?? []
    }
}

nonisolated struct PTVStop: Decodable, Identifiable {
    let stopId: Int
    let stopName: String
    let stopSuburb: String?
    let stopLandmark: String?
    let routeType: Int
    let latitude: Double
    let longitude: Double
    /// Metres from the queried coordinate. Only present on `/v3/stops/location`.
    let distanceMeters: Double?
    let stopSequence: Int?
    let disruptionIds: [Int]
    /// `/v3/stops/location` returns the routes serving each stop inline, which
    /// removes the need for a separate "routes at this stop" query.
    let routes: [PTVRoute]

    var id: Int { stopId }

    private enum CodingKeys: String, CodingKey {
        case stopId = "stop_id"
        case stopName = "stop_name"
        case stopSuburb = "stop_suburb"
        case stopLandmark = "stop_landmark"
        case routeType = "route_type"
        case latitude = "stop_latitude"
        case longitude = "stop_longitude"
        case distanceMeters = "stop_distance"
        case stopSequence = "stop_sequence"
        case disruptionIds = "disruption_ids"
        case routes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopId         = (try? c.decodeIfPresent(Int.self, forKey: .stopId)) ?? 0
        stopName       = ((try? c.decodeIfPresent(String.self, forKey: .stopName)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stopSuburb     = (try? c.decodeIfPresent(String.self, forKey: .stopSuburb)) ?? nil
        stopLandmark   = ((try? c.decodeIfPresent(String.self, forKey: .stopLandmark)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        routeType      = (try? c.decodeIfPresent(Int.self, forKey: .routeType)) ?? -1
        latitude       = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? 0
        longitude      = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? 0
        distanceMeters = (try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)) ?? nil
        stopSequence   = (try? c.decodeIfPresent(Int.self, forKey: .stopSequence)) ?? nil
        disruptionIds  = (try? c.decodeIfPresent([Int].self, forKey: .disruptionIds)) ?? []
        routes         = (try? c.decodeIfPresent([PTVRoute].self, forKey: .routes)) ?? []
    }
}

// MARK: - Route / Direction / Run

nonisolated struct PTVRoute: Decodable, Identifiable {
    let routeId: Int
    let routeName: String
    let routeNumber: String
    let routeType: Int
    let routeGTFSId: String?

    var id: Int { routeId }

    private enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case routeName = "route_name"
        case routeNumber = "route_number"
        case routeType = "route_type"
        case routeGTFSId = "route_gtfs_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routeId     = (try? c.decodeIfPresent(Int.self, forKey: .routeId)) ?? 0
        routeName   = ((try? c.decodeIfPresent(String.self, forKey: .routeName)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        routeNumber = ((try? c.decodeIfPresent(String.self, forKey: .routeNumber)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        routeType   = (try? c.decodeIfPresent(Int.self, forKey: .routeType)) ?? -1
        routeGTFSId = (try? c.decodeIfPresent(String.self, forKey: .routeGTFSId)) ?? nil
    }
}

nonisolated struct PTVDirection: Decodable, Identifiable {
    let directionId: Int
    let directionName: String
    let routeId: Int

    var id: Int { directionId }

    private enum CodingKeys: String, CodingKey {
        case directionId = "direction_id"
        case directionName = "direction_name"
        case routeId = "route_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directionId   = (try? c.decodeIfPresent(Int.self, forKey: .directionId)) ?? 0
        directionName = ((try? c.decodeIfPresent(String.self, forKey: .directionName)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        routeId       = (try? c.decodeIfPresent(Int.self, forKey: .routeId)) ?? 0
    }
}

nonisolated struct PTVRun: Decodable, Identifiable {
    let runRef: String
    let routeId: Int
    let directionId: Int
    let finalStopId: Int
    let destinationName: String
    let status: String
    let expressStopCount: Int

    var id: String { runRef }

    /// PTV reports normal services as "scheduled"; cancellations surface here
    /// rather than as a separate flag.
    var isCancelled: Bool { status.lowercased().contains("cancel") }

    private enum CodingKeys: String, CodingKey {
        case runRef = "run_ref"
        case routeId = "route_id"
        case directionId = "direction_id"
        case finalStopId = "final_stop_id"
        case destinationName = "destination_name"
        case status
        case expressStopCount = "express_stop_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runRef           = (try? c.decodeIfPresent(String.self, forKey: .runRef)) ?? ""
        routeId          = (try? c.decodeIfPresent(Int.self, forKey: .routeId)) ?? 0
        directionId      = (try? c.decodeIfPresent(Int.self, forKey: .directionId)) ?? 0
        finalStopId      = (try? c.decodeIfPresent(Int.self, forKey: .finalStopId)) ?? 0
        destinationName  = ((try? c.decodeIfPresent(String.self, forKey: .destinationName)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        status           = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        expressStopCount = (try? c.decodeIfPresent(Int.self, forKey: .expressStopCount)) ?? 0
    }
}

// MARK: - Disruption

nonisolated struct PTVDisruptionsResponse: Decodable {
    /// Keyed by mode name ("metro_train", "metro_bus", …).
    let disruptions: [String: [PTVDisruption]]

    private enum CodingKeys: String, CodingKey { case disruptions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disruptions = (try? c.decodeIfPresent([String: [PTVDisruption]].self, forKey: .disruptions)) ?? [:]
    }

    var all: [PTVDisruption] { disruptions.values.flatMap { $0 } }
}

nonisolated struct PTVDisruption: Decodable, Identifiable {
    let disruptionId: Int
    let title: String
    let url: String?
    let description: String
    let disruptionStatus: String
    let disruptionType: String
    /// PTV's own judgement of whether this belongs on a departure board.
    let displayOnBoard: Bool
    let displayStatus: Bool
    let fromDate: Date?
    let toDate: Date?
    let routes: [PTVRoute]
    let stops: [PTVStop]

    var id: Int { disruptionId }

    var isCurrent: Bool { disruptionStatus.lowercased() == "current" }

    private enum CodingKeys: String, CodingKey {
        case disruptionId = "disruption_id"
        case title
        case url
        case description
        case disruptionStatus = "disruption_status"
        case disruptionType = "disruption_type"
        case displayOnBoard = "display_on_board"
        case displayStatus = "display_status"
        case fromDate = "from_date"
        case toDate = "to_date"
        case routes
        case stops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disruptionId     = (try? c.decodeIfPresent(Int.self, forKey: .disruptionId)) ?? 0
        title            = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        description      = ((try? c.decodeIfPresent(String.self, forKey: .description)) ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        disruptionStatus = (try? c.decodeIfPresent(String.self, forKey: .disruptionStatus)) ?? ""
        disruptionType   = (try? c.decodeIfPresent(String.self, forKey: .disruptionType)) ?? ""
        displayOnBoard   = (try? c.decodeIfPresent(Bool.self, forKey: .displayOnBoard)) ?? false
        displayStatus    = (try? c.decodeIfPresent(Bool.self, forKey: .displayStatus)) ?? false
        fromDate         = (try? c.decodeIfPresent(Date.self, forKey: .fromDate)) ?? nil
        toDate           = (try? c.decodeIfPresent(Date.self, forKey: .toDate)) ?? nil
        routes           = (try? c.decodeIfPresent([PTVRoute].self, forKey: .routes)) ?? []
        stops            = (try? c.decodeIfPresent([PTVStop].self, forKey: .stops)) ?? []

        // Some records carry a literal "string" placeholder rather than a link.
        let rawURL = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        url = rawURL.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed == "string") ? nil : trimmed
        }
    }
}

// MARK: - Route Types (connectivity check)

nonisolated struct PTVRouteTypesResponse: Decodable {
    let routeTypes: [PTVRouteTypeDescriptor]

    private enum CodingKeys: String, CodingKey { case routeTypes = "route_types" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routeTypes = (try? c.decodeIfPresent([PTVRouteTypeDescriptor].self, forKey: .routeTypes)) ?? []
    }
}

nonisolated struct PTVRouteTypeDescriptor: Decodable, Identifiable {
    let routeType: Int
    let routeTypeName: String

    var id: Int { routeType }

    private enum CodingKeys: String, CodingKey {
        case routeType = "route_type"
        case routeTypeName = "route_type_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routeType     = (try? c.decodeIfPresent(Int.self, forKey: .routeType)) ?? -1
        routeTypeName = (try? c.decodeIfPresent(String.self, forKey: .routeTypeName)) ?? ""
    }
}
