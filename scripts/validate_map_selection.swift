import CoreLocation
import Foundation

@MainActor
private final class ControlledGeometryService: BusDataProviding {
    let provider: BusProvider = .queenslandTransLink
    private var pending: [String: CheckedContinuation<[[CLLocationCoordinate2D]], Error>] = [:]
    private var requestWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func fetchBusInfo(latitude: Double, longitude: Double) async throws -> BusInfo {
        preconditionFailure("Selection checks must not fetch boards")
    }

    func fetchTripDetail(for departure: BusDeparture, stopId: String) async throws -> BusTripDetail {
        preconditionFailure("Selection checks must not fetch trip details")
    }

    func fetchRouteGeometry(for departure: BusDeparture) async throws -> [[CLLocationCoordinate2D]] {
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending[departure.tripId] == nil, "Fixture already has an in-flight request")
            pending[departure.tripId] = continuation
            requestWaiters.removeValue(forKey: departure.tripId)?.resume()
        }
    }

    func waitForRequest(_ tripId: String) async {
        guard pending[tripId] == nil else { return }
        await withCheckedContinuation { requestWaiters[tripId] = $0 }
    }

    func finish(_ tripId: String, paths: [[CLLocationCoordinate2D]]) {
        guard let continuation = pending.removeValue(forKey: tripId) else {
            preconditionFailure("No pending request for \(tripId)")
        }
        continuation.resume(returning: paths)
    }

    func fail(_ tripId: String) {
        guard let continuation = pending.removeValue(forKey: tripId) else {
            preconditionFailure("No pending request for \(tripId)")
        }
        continuation.resume(throwing: URLError(.notConnectedToInternet))
    }
}

@main
@MainActor
struct MapSelectionChecks {
    static func main() async {
        await checkRefreshIdentity()
        await checkStaleCompletion()
        await checkClearAndCancellation()
        await checkCurrentFailure()
        checkMergedFavourites()
        checkNextDeparture()
        checkGroupedDepartureOrder()
        checkMatchingStops()
        checkSheetPresentation()
        print("Passed: map selection refresh identity, removal, replacement/clear/cancellation races, failures, favourite-stop merging, next departure ordering, matching stop IDs and repeated station/list reveals.")
    }

    private static func checkGroupedDepartureOrder() {
        // PTV wall-clock seconds wrap at midnight. The effective countdown
        // also determines order when a live prediction changes the schedule.
        let overnight = departure("after midnight", minutes: 110, seconds: 120)
        let earlier = departure("before midnight", minutes: 10, seconds: 80_520)
        let delayed = departure("delayed", minutes: 30, seconds: 80_160)
        let group = [overnight, delayed, earlier].groupedByDirection().first!
        precondition(group.departures.map(\.tripId) == ["before midnight", "delayed", "after midnight"])
        precondition(group.nextDeparture?.tripId == "before midnight")
    }

    private static func departure(
        _ trip: String, minutes: Int = 8, seconds: Int = 36_000,
        sequence: Int = 1, regional: Bool = false
    ) -> BusDeparture {
        BusDeparture(
            tripId: trip, routeShortName: trip, routeLongName: "Route \(trip)",
            headsign: "City", scheduledTime: "10:00 AM", scheduledSeconds: seconds,
            predictedTime: nil, delaySeconds: 0, minutesAway: minutes, status: .onTime,
            stopSequence: sequence, platform: nil, directionId: 0, directionName: "City",
            expressStopCount: 0, isAtPlatform: false, isRegional: regional
        )
    }

    private static func stop(
        _ id: String, _ departures: [BusDeparture],
        availability: DepartureDataAvailability = .available
    ) -> NearbyBusStop {
        NearbyBusStop(
            id: id, stopName: "Stop \(id)", stopCode: nil,
            latitude: -27.4, longitude: 153, distanceMeters: 50,
            departures: departures, departureDataAvailability: availability
        )
    }

    private static func selection(
        _ departure: BusDeparture, stopId: String = "s1",
        provider: BusProvider = .queenslandTransLink
    ) -> MapDepartureSelection {
        MapDepartureSelection(provider: provider, stopId: stopId, stopName: "Stop \(stopId)", departure: departure)
    }

    private static func geometry(_ marker: Double) -> [[CLLocationCoordinate2D]] {
        [[CLLocationCoordinate2D(latitude: marker, longitude: 153),
          CLLocationCoordinate2D(latitude: marker + 0.1, longitude: 153.1)]]
    }

    private static func checkRefreshIdentity() async {
        let state = MapRouteSelection()
        let service = ControlledGeometryService()
        let old = departure("A")
        state.select(selection(old))
        let load = Task { await state.load(using: service) }
        await service.waitForRequest("A")
        service.finish("A", paths: geometry(-27) + [[CLLocationCoordinate2D(latitude: 0, longitude: 0)]])
        await load.value
        precondition(state.paths.count == 1 && !state.isLoading && !state.failed)

        let refreshed = departure("A", minutes: 2)
        precondition(old.id != refreshed.id, "Fixture must reproduce refresh UUID changes")
        state.reconcile(with: [stop("s1", [refreshed])])
        precondition(state.selection?.departure.id == refreshed.id)
        precondition(state.selection?.departure.minutesAway == 2 && state.paths.count == 1)
        precondition(selection(old).geometryID == selection(refreshed).geometryID)
        precondition(selection(old).geometryID != selection(old, provider: .victorianPTV).geometryID)
        precondition(selection(old).geometryID != selection(departure("A", regional: true)).geometryID)
        precondition(!selection(old).matches(departure("A", seconds: 36_100), at: "s1"))
        precondition(!selection(old).matches(departure("A", sequence: 2), at: "s1"))
        precondition(!selection(old).matches(refreshed, at: "s2"))

        state.reconcile(with: [stop("s1", [departure("B")])])
        precondition(state.selection == nil && state.paths.isEmpty && !state.isLoading && !state.failed)
        state.select(selection(old))
        state.reconcile(with: [])
        precondition(state.selection == nil, "Removing the selected stop must clear selection")
    }

    private static func checkStaleCompletion() async {
        for oldRequestFails in [false, true] {
            let state = MapRouteSelection()
            let service = ControlledGeometryService()
            state.select(selection(departure("A")))
            let first = Task { await state.load(using: service) }
            await service.waitForRequest("A")
            state.select(selection(departure("B")))
            precondition(state.paths.isEmpty && state.isLoading)
            let second = Task { await state.load(using: service) }
            await service.waitForRequest("B")
            service.finish("B", paths: geometry(-28))
            await second.value
            if oldRequestFails { service.fail("A") }
            else { service.finish("A", paths: geometry(-27)) }
            await first.value
            precondition(state.selection?.departure.tripId == "B")
            precondition(state.paths.first?.first?.latitude == -28 && !state.failed && !state.isLoading)
        }
    }

    private static func checkClearAndCancellation() async {
        for cancellation in [false, true] {
            for requestFails in [false, true] {
                let state = MapRouteSelection()
                let service = ControlledGeometryService()
                state.select(selection(departure("A")))
                let load = Task { await state.load(using: service) }
                await service.waitForRequest("A")
                if cancellation { load.cancel() }
                else { state.clear() }
                if requestFails { service.fail("A") }
                else { service.finish("A", paths: geometry(-27)) }
                await load.value
                precondition(state.paths.isEmpty && !state.failed, "Late results must not publish after clear/cancel")
                if !cancellation { precondition(state.selection == nil && !state.isLoading) }
                state.clear()
                precondition(!state.isLoading)
            }
        }
    }

    private static func checkCurrentFailure() async {
        let state = MapRouteSelection()
        let service = ControlledGeometryService()
        state.select(selection(departure("A")))
        let load = Task { await state.load(using: service) }
        await service.waitForRequest("A")
        service.fail("A")
        await load.value
        precondition(state.failed && !state.isLoading && state.paths.isEmpty && state.selection != nil)
        state.clear()
        precondition(!state.failed && state.selection == nil)
    }

    private static func checkMergedFavourites() {
        let nearbyA = departure("A", minutes: 3)
        let favouriteA = departure("A", minutes: 4)
        let favouriteB = departure("B", minutes: 7)
        let duplicates = [
            stop("s1", [nearbyA], availability: .unavailable),
            stop("s1", [favouriteA, favouriteB, departure("B", minutes: 9)]),
            stop("s2", [departure("C")])
        ].uniqueStops
        precondition(duplicates.map(\.id) == ["s1", "s2"])
        precondition(duplicates[0].departures.map(\.tripId) == ["A", "B"])
        precondition(duplicates[0].departures[0].minutesAway == 3, "Prefer first board's fresh shared departure")
        precondition(duplicates[0].departureDataAvailability == .available)

        let state = MapRouteSelection()
        state.select(selection(favouriteB))
        state.reconcile(with: duplicates)
        precondition(state.selection?.departure.tripId == "B", "Nearby route filtering must not erase favourite route B")
        precondition(state.matchingStopIDs(in: duplicates) == ["s1"])

        let distinctDepartures = [
            stop("s1", [favouriteB]),
            stop("s1", [departure("B", regional: true), departure("B", sequence: 2),
                        departure("B", seconds: 37_000)])
        ].uniqueStops
        precondition(distinctDepartures[0].departures.count == 4,
                     "Regional runs, repeated-stop visits and separate scheduled departures must remain distinct")
    }

    private static func checkNextDeparture() {
        let stops = [
            stop("s1", [departure("past", minutes: -1), departure("due", minutes: 0)]),
            stop("s2", [departure("later", minutes: 5, seconds: 37_000),
                        departure("earlier", minutes: 5, seconds: 36_000)]),
            stop("empty", [departure("gone", minutes: -2)])
        ]
        precondition(stops.nextMapDeparture(selectedStopID: nil)?.departure.tripId == "due")
        precondition(stops.nextMapDeparture(selectedStopID: "missing")?.departure.tripId == "due")
        precondition(stops.nextMapDeparture(selectedStopID: "s2")?.departure.tripId == "earlier")
        precondition(stops.nextMapDeparture(selectedStopID: "empty") == nil)
        precondition([NearbyBusStop]().nextMapDeparture(selectedStopID: nil) == nil)
    }

    private static func checkMatchingStops() {
        let state = MapRouteSelection()
        let stops = [stop("s1", [departure("A")]),
                     stop("s2", [departure("A", sequence: 2)]),
                     stop("s3", [departure("B")])]
        precondition(state.matchingStopIDs(in: stops).isEmpty)
        state.select(selection(departure("A")))
        precondition(state.matchingStopIDs(in: stops) == ["s1", "s2"])
        state.clear()
        precondition(state.matchingStopIDs(in: stops).isEmpty)
    }

    private static func checkSheetPresentation() {
        let presentation = MapSheetPresentation()
        precondition(presentation.detent == .medium && presentation.focusedStopID == nil)
        let initialReveal = presentation.revealID

        presentation.detent = .collapsed
        presentation.showDepartures(at: "s1")
        precondition(presentation.detent == .expanded && presentation.focusedStopID == "s1",
                     "Station selection must immediately reveal a collapsed sheet")
        precondition(presentation.revealID != initialReveal)

        let firstStationReveal = presentation.revealID
        presentation.showDepartures(at: "s1")
        precondition(presentation.revealID != firstStationReveal,
                     "Tapping the same station again must issue a new scroll request")
        precondition(presentation.detent == .expanded && presentation.focusedStopID == "s1")

        let repeatedStationReveal = presentation.revealID
        presentation.detent = .collapsed
        presentation.showDepartures(at: "s2")
        precondition(presentation.focusedStopID == "s2" && presentation.detent == .expanded)
        precondition(presentation.revealID != repeatedStationReveal)

        let secondStationReveal = presentation.revealID
        presentation.detent = .collapsed
        presentation.showDepartures()
        precondition(presentation.detent == .expanded && presentation.focusedStopID == nil,
                     "Explicit Show departures must reveal the top of the full list")
        precondition(presentation.revealID != secondStationReveal)

        let firstListReveal = presentation.revealID
        presentation.showDepartures()
        precondition(presentation.revealID != firstListReveal && presentation.focusedStopID == nil)
        precondition(presentation.detent == .expanded)
    }
}
