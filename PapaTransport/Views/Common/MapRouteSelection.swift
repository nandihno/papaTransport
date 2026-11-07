import CoreLocation
import Observation
import SwiftUI

struct MapDepartureSelection {
    let provider: BusProvider
    let stopId: String
    let stopName: String
    let departure: BusDeparture

    var geometryID: String {
        "\(provider.rawValue):\(departure.isRegional):\(departure.tripId)"
    }

    var title: String {
        let route = departure.routeShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = (departure.headsign ?? departure.routeLongName).trimmingCharacters(in: .whitespacesAndNewlines)
        if route.isEmpty { return destination.isEmpty ? "Selected service" : destination }
        return destination.isEmpty || destination == route ? route : "\(route) · \(destination)"
    }

    func matches(_ candidate: BusDeparture, at stopId: String) -> Bool {
        self.stopId == stopId && departure.tripId == candidate.tripId
            && departure.scheduledSeconds == candidate.scheduledSeconds
            && departure.stopSequence == candidate.stopSequence
    }
}

/// Shared selection for the map and board. IDs use feed identity rather than
/// BusDeparture's UUID, which changes on every board refresh.
@MainActor @Observable
final class MapRouteSelection {
    private(set) var selection: MapDepartureSelection?
    private(set) var paths: [[CLLocationCoordinate2D]] = []
    private(set) var isLoading = false
    private(set) var failed = false

    func select(_ selection: MapDepartureSelection) {
        if self.selection?.geometryID != selection.geometryID {
            paths = []
            failed = false
            isLoading = true
        }
        self.selection = selection
    }

    func clear() {
        selection = nil
        paths = []
        isLoading = false
        failed = false
    }

    func reconcile(with stops: [NearbyBusStop]) {
        guard let selection else { return }
        guard let stop = stops.first(where: { $0.id == selection.stopId }),
              let departure = stop.departures.first(where: { selection.matches($0, at: stop.id) })
        else {
            clear()
            return
        }
        select(MapDepartureSelection(provider: selection.provider, stopId: stop.id,
                                     stopName: stop.stopName, departure: departure))
    }

    func load(using service: any BusDataProviding) async {
        guard let request = selection else { return }
        isLoading = true
        defer {
            if selection?.geometryID == request.geometryID && !Task.isCancelled {
                isLoading = false
            }
        }
        do {
            let paths = try await service.fetchRouteGeometry(for: request.departure)
            guard !Task.isCancelled, selection?.geometryID == request.geometryID else { return }
            self.paths = paths.filter { $0.count > 1 }
            failed = false
        } catch {
            guard !Task.isCancelled, selection?.geometryID == request.geometryID else { return }
            paths = []
            failed = true
        }
    }

    func matchingStopIDs(in stops: [NearbyBusStop]) -> Set<String> {
        guard let selection else { return [] }
        return Set(stops.filter { stop in
            stop.departures.contains { $0.tripId == selection.departure.tripId }
        }.map(\.id))
    }
}

struct MapRouteSelectionControls: View {
    let route: MapRouteSelection
    let onShowDetails: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        if let selection = route.selection {
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.title)
                    .font(.transitLabel)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                if route.isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading route…")
                    }
                    .font(.transitCaption)
                } else if route.paths.isEmpty {
                    Text(route.failed ? "Route unavailable. Check your connection." : "Route geometry unavailable for this service.")
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                }
                HStack {
                    Button("Trip details", action: onShowDetails)
                    Spacer(minLength: 8)
                    Button("Clear", systemImage: "xmark", action: route.clear)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Clear selected route")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .font(.transitLabel)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        }
    }
}

extension Array where Element == NearbyBusStop {
    var uniqueStops: [NearbyBusStop] {
        var result: [NearbyBusStop] = []
        var indices: [String: Int] = [:]
        for stop in self {
            guard let index = indices[stop.id] else {
                indices[stop.id] = result.count
                result.append(stop)
                continue
            }
            let existing = result[index]
            var seen: Set<String> = []
            let departures = (existing.departures + stop.departures).filter {
                seen.insert("\($0.isRegional):\($0.tripId):\($0.stopSequence):\($0.scheduledSeconds)").inserted
            }
            result[index] = NearbyBusStop(
                id: existing.id, stopName: existing.stopName, stopCode: existing.stopCode,
                latitude: existing.latitude, longitude: existing.longitude,
                distanceMeters: existing.distanceMeters, departures: departures,
                departureDataAvailability: existing.departureDataAvailability == .available
                    || stop.departureDataAvailability == .available ? .available : .unavailable
            )
        }
        return result
    }

    func nextMapDeparture(selectedStopID: String?) -> (stop: NearbyBusStop, departure: BusDeparture)? {
        let candidates = selectedStopID.flatMap { id in first { $0.id == id } }.map { [$0] } ?? self
        return candidates.flatMap { stop in
            stop.departures.filter { $0.minutesAway >= 0 }.map { (stop: stop, departure: $0) }
        }.min {
            if $0.departure.minutesAway != $1.departure.minutesAway {
                return $0.departure.minutesAway < $1.departure.minutesAway
            }
            return $0.departure.scheduledSeconds < $1.departure.scheduledSeconds
        }
    }
}
