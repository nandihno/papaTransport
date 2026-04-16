//
//  BusModels.swift
//  myLatest
//
//  App-level models for displaying bus departure information.
//  Combines static GTFS schedule data with GTFS-RT real-time predictions.
//

import Foundation

// MARK: - Transport Region

enum TransportRegion: String, CaseIterable {
    case victorian   = "victorian"
    case queensland  = "queensland"

    var displayName: String {
        switch self {
        case .victorian:  return "Victorian Transport"
        case .queensland: return "Queensland Transport"
        }
    }
}

// MARK: - Bus Provider

enum BusProvider: String, Codable, CaseIterable {
    case queenslandTransLink = "queenslandTransLink"
    case queenslandTrainTransLink = "queenslandTrainTransLink"
    case victorianPTV = "victorianPTV"
    case victorianTrainPTV = "victorianTrainPTV"

    var displayName: String {
        switch self {
        case .queenslandTransLink:
            return "TransLink SEQ"
        case .queenslandTrainTransLink:
            return "TransLink SEQ Rail"
        case .victorianPTV:
            return "PTV Victoria"
        case .victorianTrainPTV:
            return "PTV Victoria Train"
        }
    }

    var region: TransportRegion {
        switch self {
        case .queenslandTransLink, .queenslandTrainTransLink:
            return .queensland
        case .victorianPTV, .victorianTrainPTV:
            return .victorian
        }
    }
}

protocol BusDataProviding {
    var provider: BusProvider { get }
    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo
    func fetchTripDetail(for departure: BusDeparture, stopId: String) async throws -> BusTripDetail
}

// MARK: - Bus Info (top-level model for BusCard)

struct BusInfo: Identifiable {
    let id = UUID()
    let provider: BusProvider
    let nearbyStops: [NearbyBusStop]
    let favouriteStops: [NearbyBusStop]
    let alerts: [BusAlert]
    let localTimeAtFetch: String      // e.g. "2:22 PM"
    let locationAvailable: Bool
}

// MARK: - Nearby Bus Stop

struct NearbyBusStop: Identifiable {
    let id: String                    // stop_id
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double
    let distanceMeters: Int
    let departures: [BusDeparture]
}

// MARK: - Bus Departure

struct BusDeparture: Identifiable {
    let id = UUID()
    let tripId: String
    let routeShortName: String        // e.g. "333"
    let routeLongName: String         // e.g. "Upper Mt Gravatt to City"
    let headsign: String?             // e.g. "Upper Mt Gravatt"
    let scheduledTime: String         // "2:22 PM" (Brisbane time)
    let scheduledSeconds: Int         // seconds since midnight
    let predictedTime: String?        // "2:24 PM" or nil if no RT data
    let delaySeconds: Int             // positive = late, negative = early
    let minutesAway: Int              // minutes until departure
    let status: BusDepartureStatus
    let stopSequence: Int
}

struct BusTripDetail: Identifiable {
    let id: String
    let tripId: String
    let routeShortName: String
    let routeLongName: String
    let headsign: String?
    let selectedStopName: String
    let selectedStopSequence: Int
    let earlierStopCount: Int
    let remainingStopCount: Int
    let terminalStopName: String
    let terminalScheduledTime: String?
    let terminalPredictedTime: String?
    let stopsFromSelected: [BusTripStopDetail]

    init(
        tripId: String,
        routeShortName: String,
        routeLongName: String,
        headsign: String?,
        selectedStopName: String,
        selectedStopSequence: Int,
        earlierStopCount: Int,
        remainingStopCount: Int,
        terminalStopName: String,
        terminalScheduledTime: String?,
        terminalPredictedTime: String?,
        stopsFromSelected: [BusTripStopDetail]
    ) {
        self.id = tripId
        self.tripId = tripId
        self.routeShortName = routeShortName
        self.routeLongName = routeLongName
        self.headsign = headsign
        self.selectedStopName = selectedStopName
        self.selectedStopSequence = selectedStopSequence
        self.earlierStopCount = earlierStopCount
        self.remainingStopCount = remainingStopCount
        self.terminalStopName = terminalStopName
        self.terminalScheduledTime = terminalScheduledTime
        self.terminalPredictedTime = terminalPredictedTime
        self.stopsFromSelected = stopsFromSelected
    }
}

struct BusTripStopDetail: Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double
    let scheduledTime: String?
    let predictedTime: String?
    let delaySeconds: Int?
    let status: BusDepartureStatus?
    let stopSequence: Int
    let isSelectedStop: Bool

    var id: String { "\(stopId):\(stopSequence)" }
}

enum BusDepartureStatus: String {
    case onTime  = "On Time"
    case early   = "Early"
    case late    = "Late"
    case noData  = "Scheduled"
    case skipped = "Not Stopping"

    var color: String {
        switch self {
        case .onTime:  return "green"
        case .early:   return "blue"
        case .late:    return "orange"
        case .noData:  return "secondary"
        case .skipped: return "red"
        }
    }
}

// MARK: - Bus Alert

struct BusAlert: Identifiable {
    let id = UUID()
    let headerText: String
    let descriptionText: String?
    let severity: BusAlertSeverity
    let effect: String
    let affectedRoutes: [String]      // route_ids affected
    let affectedStops: [String]       // stop_ids affected
}

enum BusAlertSeverity: String {
    case info    = "info"
    case warning = "warning"
    case severe  = "severe"

    var symbolName: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .severe:  return "xmark.octagon.fill"
        }
    }
}

// MARK: - Mock data

extension BusInfo {
    static func placeholder(provider: BusProvider = .queenslandTransLink) -> BusInfo {
        let now = Date()
        let zoneIdentifier = switch provider {
        case .queenslandTransLink, .queenslandTrainTransLink: "Australia/Brisbane"
        case .victorianPTV, .victorianTrainPTV: "Australia/Melbourne"
        }
        let localZone = TimeZone(identifier: zoneIdentifier) ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = localZone

        return BusInfo(
            provider: provider,
            nearbyStops: [
                NearbyBusStop(
                    id: "placeholder-1",
                    stopName: "Nearby bus stop",
                    stopCode: "000",
                    latitude: -27.4698,
                    longitude: 153.0251,
                    distanceMeters: 120,
                    departures: (0..<3).map { i in
                        BusDeparture(
                            tripId: "mock-\(i)",
                            routeShortName: "---",
                            routeLongName: "Loading route name",
                            headsign: "Loading...",
                            scheduledTime: formatter.string(from: now.addingTimeInterval(Double(i * 600))),
                            scheduledSeconds: 0,
                            predictedTime: nil,
                            delaySeconds: 0,
                            minutesAway: i * 10 + 5,
                            status: .noData,
                            stopSequence: 0
                        )
                    }
                )
            ],
            favouriteStops: [],
            alerts: [],
            localTimeAtFetch: "--:-- --",
            locationAvailable: true
        )
    }

    static func noLocation(provider: BusProvider = .queenslandTransLink) -> BusInfo {
        BusInfo(
            provider: provider,
            nearbyStops: [],
            favouriteStops: [],
            alerts: [],
            localTimeAtFetch: "--:-- --",
            locationAvailable: false
        )
    }
}
