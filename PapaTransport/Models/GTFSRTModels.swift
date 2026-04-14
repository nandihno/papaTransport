//
//  GTFSRTModels.swift
//  myLatest
//
//  Typed Swift models decoded from GTFS-RT protobuf binary data.
//  Covers: FeedMessage, TripUpdate, StopTimeUpdate, Alert, EntitySelector.
//  Reference: https://gtfs.org/realtime/reference/
//

import Foundation

// MARK: - FeedMessage (root)

struct GTFSRTFeedMessage {
    let timestamp: UInt64                  // header.timestamp (POSIX seconds)
    let entities: [GTFSRTFeedEntity]

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()

        // header = field 1 (embedded message)
        if let headerData = fields.first(1)?.asData {
            var hReader = ProtobufReader(data: headerData)
            let hFields = try hReader.readAllFields()
            self.timestamp = hFields.first(3)?.asUInt64 ?? 0
        } else {
            self.timestamp = 0
        }

        // entity = field 2 (repeated)
        self.entities = try fields.all(2).compactMap { value -> GTFSRTFeedEntity? in
            guard let entityData = value.asData else { return nil }
            return try GTFSRTFeedEntity(data: entityData)
        }
    }
}

// MARK: - FeedEntity

struct GTFSRTFeedEntity {
    let id: String
    let tripUpdate: GTFSRTTripUpdate?
    let alert: GTFSRTAlert?

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()

        self.id = fields.first(1)?.asString ?? ""

        // trip_update = field 3
        if let tuData = fields.first(3)?.asData {
            self.tripUpdate = try GTFSRTTripUpdate(data: tuData)
        } else {
            self.tripUpdate = nil
        }

        // alert = field 5
        if let aData = fields.first(5)?.asData {
            self.alert = try GTFSRTAlert(data: aData)
        } else {
            self.alert = nil
        }
    }
}

// MARK: - TripUpdate

struct GTFSRTTripUpdate {
    let tripId: String
    let routeId: String
    let directionId: UInt32
    let scheduleRelationship: GTFSRTScheduleRelationship
    let stopTimeUpdates: [GTFSRTStopTimeUpdate]
    let timestamp: UInt64
    let delay: Int32?

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()

        // trip = field 1 (embedded TripDescriptor)
        if let tripData = fields.first(1)?.asData {
            var tReader = ProtobufReader(data: tripData)
            let tFields = try tReader.readAllFields()
            self.tripId = tFields.first(1)?.asString ?? ""
            self.routeId = tFields.first(5)?.asString ?? ""
            self.directionId = UInt32(tFields.first(6)?.asUInt64 ?? 0)
            self.scheduleRelationship = GTFSRTScheduleRelationship(
                rawValue: Int(tFields.first(4)?.asUInt64 ?? 0)) ?? .scheduled
        } else {
            self.tripId = ""
            self.routeId = ""
            self.directionId = 0
            self.scheduleRelationship = .scheduled
        }

        // stop_time_update = field 2 (repeated)
        self.stopTimeUpdates = try fields.all(2).compactMap { value -> GTFSRTStopTimeUpdate? in
            guard let stuData = value.asData else { return nil }
            return try GTFSRTStopTimeUpdate(data: stuData)
        }

        self.timestamp = fields.first(4)?.asUInt64 ?? 0

        // delay = field 5 (optional int32)
        self.delay = fields.first(5)?.asInt32
    }
}

// MARK: - StopTimeUpdate

struct GTFSRTStopTimeUpdate {
    let stopSequence: UInt32
    let stopId: String
    let arrival: GTFSRTStopTimeEvent?
    let departure: GTFSRTStopTimeEvent?
    let scheduleRelationship: GTFSRTStopScheduleRelationship

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()

        self.stopSequence = UInt32(fields.first(1)?.asUInt64 ?? 0)
        self.stopId = fields.first(4)?.asString ?? ""

        // arrival = field 2
        if let aData = fields.first(2)?.asData {
            self.arrival = try GTFSRTStopTimeEvent(data: aData)
        } else {
            self.arrival = nil
        }

        // departure = field 3
        if let dData = fields.first(3)?.asData {
            self.departure = try GTFSRTStopTimeEvent(data: dData)
        } else {
            self.departure = nil
        }

        self.scheduleRelationship = GTFSRTStopScheduleRelationship(
            rawValue: Int(fields.first(5)?.asUInt64 ?? 0)) ?? .scheduled
    }
}

// MARK: - StopTimeEvent

struct GTFSRTStopTimeEvent {
    let delay: Int32       // seconds late (+) or early (-)
    let time: Int64        // absolute POSIX timestamp
    let uncertainty: Int32

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()

        self.delay = fields.first(1)?.asInt32 ?? 0
        self.time = fields.first(2)?.asInt64 ?? 0
        self.uncertainty = fields.first(3)?.asInt32 ?? 0
    }
}

// MARK: - Alert

struct GTFSRTAlert {
    let activePeriods: [GTFSRTTimeRange]
    let informedEntities: [GTFSRTEntitySelector]
    let cause: GTFSRTAlertCause
    let effect: GTFSRTAlertEffect
    let headerText: String?
    let descriptionText: String?
    let severityLevel: GTFSRTSeverityLevel

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()

        // active_period = field 1 (repeated)
        self.activePeriods = try fields.all(1).compactMap { value -> GTFSRTTimeRange? in
            guard let d = value.asData else { return nil }
            return try GTFSRTTimeRange(data: d)
        }

        // informed_entity = field 5 (repeated)
        self.informedEntities = try fields.all(5).compactMap { value -> GTFSRTEntitySelector? in
            guard let d = value.asData else { return nil }
            return try GTFSRTEntitySelector(data: d)
        }

        self.cause = GTFSRTAlertCause(rawValue: Int(fields.first(6)?.asUInt64 ?? 1)) ?? .unknownCause
        self.effect = GTFSRTAlertEffect(rawValue: Int(fields.first(7)?.asUInt64 ?? 8)) ?? .otherEffect
        self.headerText = try Self.extractTranslatedString(from: fields.first(10))
        self.descriptionText = try Self.extractTranslatedString(from: fields.first(11))
        self.severityLevel = GTFSRTSeverityLevel(rawValue: Int(fields.first(14)?.asUInt64 ?? 1)) ?? .info
    }

    private static func extractTranslatedString(from value: ProtobufValue?) throws -> String? {
        guard let data = value?.asData else { return nil }
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()
        // TranslatedString has repeated Translation (field 1)
        // Translation: text = field 1, language = field 2
        for translationValue in fields.all(1) {
            guard let tData = translationValue.asData else { continue }
            var tReader = ProtobufReader(data: tData)
            let tFields = try tReader.readAllFields()
            if let text = tFields.first(1)?.asString {
                return text
            }
        }
        return nil
    }
}

// MARK: - TimeRange

struct GTFSRTTimeRange {
    let start: UInt64   // 0 = from now
    let end: UInt64     // 0 = indefinite

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()
        self.start = fields.first(1)?.asUInt64 ?? 0
        self.end = fields.first(2)?.asUInt64 ?? 0
    }
}

// MARK: - EntitySelector

struct GTFSRTEntitySelector {
    let agencyId: String?
    let routeId: String?
    let routeType: Int32?
    let stopId: String?

    init(data: Data) throws {
        var reader = ProtobufReader(data: data)
        let fields = try reader.readAllFields()
        self.agencyId = fields.first(1)?.asString
        self.routeId = fields.first(2)?.asString
        self.routeType = fields.first(3)?.asInt32
        self.stopId = fields.first(5)?.asString
    }
}

// MARK: - Enums

enum GTFSRTScheduleRelationship: Int {
    case scheduled   = 0
    case added       = 1
    case unscheduled = 2
    case canceled    = 3
    case replacement = 5
}

enum GTFSRTStopScheduleRelationship: Int {
    case scheduled   = 0
    case skipped     = 1
    case noData      = 2
    case unscheduled = 3
}

enum GTFSRTAlertCause: Int {
    case unknownCause     = 1
    case otherCause       = 2
    case technicalProblem = 3
    case strike           = 4
    case demonstration    = 5
    case accident         = 6
    case holiday          = 7
    case weather          = 8
    case maintenance      = 9
    case construction     = 10
    case policeActivity   = 11
    case medicalEmergency = 12
}

enum GTFSRTAlertEffect: Int {
    case noService          = 1
    case reducedService     = 2
    case significantDelays  = 3
    case detour             = 4
    case additionalService  = 5
    case modifiedService    = 6
    case otherEffect        = 7
    case unknownEffect      = 8
    case stopMoved          = 9
    case noEffect           = 10
    case accessibilityIssue = 11
}

enum GTFSRTSeverityLevel: Int {
    case unknownSeverity = 0
    case info            = 1
    case warning         = 2
    case severe          = 3
}
