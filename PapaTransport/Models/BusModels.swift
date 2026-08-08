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
    case victorianTramPTV = "victorianTramPTV"

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
        case .victorianTramPTV:
            return "PTV Victoria Tram"
        }
    }

    var region: TransportRegion {
        switch self {
        case .queenslandTransLink, .queenslandTrainTransLink:
            return .queensland
        case .victorianPTV, .victorianTrainPTV, .victorianTramPTV:
            return .victorian
        }
    }

    // MARK: - Presentation
    //
    // Bus, tram and train boards share the same views, so user-facing wording
    // and symbols come from the provider rather than being hardcoded.

    /// Tab-style title: "Bus", "Trains", "Trams".
    var modeTitle: String {
        switch self {
        case .queenslandTransLink, .victorianPTV: return "Bus"
        case .queenslandTrainTransLink, .victorianTrainPTV: return "Trains"
        case .victorianTramPTV: return "Trams"
        }
    }

    /// Title-cased plural for headings: "Bus Stops", "Train Stations", "Tram Stops".
    var stopsTitle: String {
        switch self {
        case .queenslandTransLink, .victorianPTV: return "Bus Stops"
        case .queenslandTrainTransLink, .victorianTrainPTV: return "Train Stations"
        case .victorianTramPTV: return "Tram Stops"
        }
    }

    /// Lower-cased plural for inline sentences: "bus stops", "train stations", "tram stops".
    var stopsNoun: String {
        stopsTitle.lowercased()
    }

    var symbolName: String {
        switch self {
        case .queenslandTransLink, .victorianPTV: return "bus.fill"
        case .queenslandTrainTransLink, .victorianTrainPTV: return "tram.fill"
        case .victorianTramPTV: return "cablecar.fill"
        }
    }
}

protocol BusDataProviding {
    var provider: BusProvider { get }
    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo
    func fetchTripDetail(for departure: BusDeparture, stopId: String) async throws -> BusTripDetail
}

/// Boards that can also render saved stops.
protocol FavouritesBoardProviding: BusDataProviding {
    func fetchFavouriteBusInfo(referenceLatitude latitude: Double, longitude: Double) async throws -> BusInfo
}

/// Train boards additionally support the map explorer's region query.
protocol TrainBoardProviding: FavouritesBoardProviding {
    func fetchBusInfo(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        referenceLatitude: Double,
        referenceLongitude: Double
    ) async throws -> BusInfo
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

    /// Live vehicles serving this board.
    ///
    /// Victoria only. PTV attaches vehicle positions to the departures response
    /// the board already fetches, so they arrive with the board rather than
    /// from a separate feed — which also means the set is scoped to runs
    /// serving these stops, not everything in the viewport.
    ///
    /// Queensland leaves this empty: TransLink publishes a separate
    /// network-wide VehiclePositions feed, which `QLDVehiclePositionService`
    /// fetches and filters by viewport instead.
    ///
    /// `var` with a default so the 30-odd existing construction sites, none of
    /// which have vehicles to supply, stay untouched.
    var liveVehicles: [LiveVehicle] = []
}

// MARK: - Nearby Bus Stop

nonisolated enum DepartureDataAvailability: Equatable, Sendable {
    case available
    case unavailable
}

struct NearbyBusStop: Identifiable {
    let id: String                    // stop_id
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double
    let distanceMeters: Int
    let departures: [BusDeparture]
    var departureDataAvailability: DepartureDataAvailability = .available
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
    /// PTV only — GTFS-only feeds (Queensland) have no platform field wired
    /// through yet, though SEQ `stops.txt` does carry one for a future pass.
    let platform: String?
    /// Raw direction id. Queensland supplies this from `trips.direction_id`
    /// (0/1, no semantics); PTV from the departure itself.
    let directionId: Int?
    /// A rider-facing direction label ("City", "Werribee"). PTV only — GTFS
    /// has no equivalent table, so grouping falls back to `headsign` when this
    /// is nil. See `BusDeparture.groupingLabel`.
    let directionName: String?
    /// Stops skipped on this run. PTV only; 0 for GTFS-only feeds.
    let expressStopCount: Int
    /// PTV only; false for GTFS-only feeds.
    let isAtPlatform: Bool
    /// A V/Line regional service rather than a metropolitan one. Victorian
    /// train boards merge both, and the two are different PTV route types, so
    /// the trip-detail lookup needs to know which one this came from.
    let isRegional: Bool
    /// How many stops the vehicle still has to make before reaching this one.
    ///
    /// Queensland only, derived from `current_stop_sequence` on the
    /// VehiclePositions feed. Nil whenever no vehicle is reporting for this
    /// trip, which is the normal case for a service that has not started yet.
    var stopsAway: Int?
}

/// `nonisolated` because the Queensland services call `stopsAway` while
/// building boards off the main actor — see the note on default main-actor
/// isolation in CLAUDE.md.
nonisolated extension BusDeparture {
    /// Stops remaining between a reporting vehicle and this stop.
    ///
    /// Returns nil when no vehicle is reporting, and also when the vehicle has
    /// already passed — a negative count would otherwise render as nonsense on
    /// a departure the board is about to drop anyway.
    static func stopsAway(toStopSequence stopSequence: Int, vehicleSequence: Int?) -> Int? {
        guard let vehicleSequence else { return nil }
        let remaining = stopSequence - vehicleSequence
        return remaining >= 0 ? remaining : nil
    }

    /// Rider-facing phrasing for `stopsAway`.
    var stopsAwayDescription: String? {
        switch stopsAway {
        case .none: nil
        case 0: "At this stop"
        case 1: "1 stop away"
        case let count?: "\(count) stops away"
        }
    }
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
    let stopsBeforeSelected: [BusTripStopDetail]
    let stopsFromSelected: [BusTripStopDetail]
    /// What the vehicle physically is — "6 Car Xtrapolis · 142m". Victoria only;
    /// TransLink publishes no equivalent.
    let vehicleDescription: String?

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
        stopsBeforeSelected: [BusTripStopDetail] = [],
        stopsFromSelected: [BusTripStopDetail],
        vehicleDescription: String? = nil
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
        self.stopsBeforeSelected = stopsBeforeSelected
        self.stopsFromSelected = stopsFromSelected
        self.vehicleDescription = vehicleDescription
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
        case .victorianPTV, .victorianTrainPTV, .victorianTramPTV: "Australia/Melbourne"
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
                            stopSequence: 0,
                            platform: nil,
                            directionId: nil,
                            directionName: nil,
                            expressStopCount: 0,
                            isAtPlatform: false,
                            isRegional: false
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
