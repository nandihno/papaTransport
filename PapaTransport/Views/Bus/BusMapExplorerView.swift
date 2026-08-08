import CoreLocation
import MapKit
import SwiftUI

struct BusMapExplorerView: View {
    let provider: BusProvider
    let initialBusInfo: BusInfo?
    let onOpenSettings: () -> Void
    let onRefresh: () async -> Void
    let autoRefreshEnabled: Bool
    let statusMessage: String?
    let statusDetail: String?
    let progressStage: String?
    let progressDetail: String?

    @Environment(\.themePalette) private var palette

    @State private var nearbyBusInfo: BusInfo
    @State private var favouriteBusInfo: BusInfo
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedStopID: String?
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var lastQueriedCenter: CLLocationCoordinate2D?
    @State private var userCoordinate: CLLocationCoordinate2D?
    @State private var reloadTask: Task<Void, Never>?
    @State private var hasBootstrapped = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var routeSearchText = ""
    @State private var currentRegion: MKCoordinateRegion?
    @State private var liveVehicles: [LiveVehicle] = []
    /// Opened by tapping a vehicle pin. The board's own rows open the same
    /// sheet from inside `BusCard`, which keeps its own state.
    @State private var selectedTripRequest: BusTripRequest?

    private static let autoRefreshInterval: Duration = .seconds(60)

    init(
        provider: BusProvider,
        initialBusInfo: BusInfo? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {},
        autoRefreshEnabled: Bool = true,
        statusMessage: String? = nil,
        statusDetail: String? = nil,
        progressStage: String? = nil,
        progressDetail: String? = nil
    ) {
        self.provider = provider
        self.initialBusInfo = initialBusInfo
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.autoRefreshEnabled = autoRefreshEnabled
        self.statusMessage = statusMessage
        self.statusDetail = statusDetail
        self.progressStage = progressStage
        self.progressDetail = progressDetail
        let seed = initialBusInfo ?? .placeholder(provider: provider)
        _nearbyBusInfo = State(initialValue: seed)
        _favouriteBusInfo = State(initialValue: seed)
    }

    private var searchCenter: CLLocationCoordinate2D? {
        mapCenter ?? lastQueriedCenter
    }

    private var normalizedRouteSearchText: String {
        routeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRouteSearchActive: Bool {
        !normalizedRouteSearchText.isEmpty
    }

    private var displayedNearbyStops: [NearbyBusStop] {
        filteredNearbyStops(from: nearbyBusInfo.nearbyStops, query: normalizedRouteSearchText)
    }

    private var displayedNearbyStopIDs: [String] {
        displayedNearbyStops.map(\.id)
    }

    private var displayedNearbyBusInfo: BusInfo {
        BusInfo(
            provider: nearbyBusInfo.provider,
            nearbyStops: displayedNearbyStops,
            favouriteStops: nearbyBusInfo.favouriteStops,
            alerts: nearbyBusInfo.alerts,
            localTimeAtFetch: nearbyBusInfo.localTimeAtFetch,
            locationAvailable: nearbyBusInfo.locationAvailable
        )
    }

    private var mapSummary: String {
        let count = displayedNearbyStops.count
        let stopLabel = count == 1 ? "stop" : "stops"
        if isRouteSearchActive {
            return "\(count) \(stopLabel) for \(normalizedRouteSearchText) within 300m"
        }
        return "\(count) \(stopLabel) within 300m"
    }

    private var screenTitle: String {
        provider.modeTitle
    }

    private var nearbyCardTitle: String {
        isRouteSearchActive
            ? "Nearby \(provider.stopsTitle) for \(normalizedRouteSearchText)"
            : "Nearby \(provider.stopsTitle)"
    }

    private var nearbyEmptyStateMessage: String? {
        guard isRouteSearchActive else { return nil }

        if nearbyBusInfo.nearbyStops.contains(where: { $0.departureDataAvailability == .unavailable }) {
            return "Route search requires live departures. Clear the route search to see cached stop locations."
        }

        return "No upcoming route \(normalizedRouteSearchText) departures were found at \(provider.stopsNoun) within 300m of the map center. Pan the map to search elsewhere or clear the route search."
    }

    var body: some View {
        MapSheetScaffold(
            title: "Nearby \(provider.stopsTitle)",
            summary: mapSummary,
            isLoading: isLoading,
            onOpenSettings: onOpenSettings,
            onRecenter: recenterOnUser,
            onRefresh: { await refreshAll() }
        ) {
            mapCard
        } headerContent: {
            headerPill
        } sheetContent: {
            sheetSections
        }
        .task {
            await bootstrap()
        }
        .task(id: autoRefreshEnabled) {
            await runAutoRefreshLoop()
        }
        .onDisappear {
            reloadTask?.cancel()
        }
        .onChange(of: displayedNearbyStopIDs) { _, _ in
            synchronizeSelectedStopWithDisplayedStops()
        }
        .sheet(item: $selectedTripRequest) { request in
            BusTripDetailSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var mapCard: some View {
        Map(position: $cameraPosition, selection: $selectedStopID) {
            UserAnnotation()

            if let searchCenter {
                MapCircle(center: searchCenter, radius: 300)
                    .foregroundStyle(palette.accent.opacity(0.12))
                    .stroke(palette.accentStrong.opacity(0.28), lineWidth: 1.5)
            }

            ForEach(displayedNearbyStops) { stop in
                Annotation(stop.stopName, coordinate: stop.coordinate, anchor: .bottom) {
                    BusStopMapPin(
                        stop: stop,
                        isSelected: selectedStopID == stop.id,
                        accentColor: palette.accent,
                        symbolName: provider.symbolName
                    )
                }
                .tag(stop.id)
            }

            // Untagged so they stay out of the stop-selection binding.
            ForEach(vehicleAnnotations) { annotation in
                Annotation("", coordinate: annotation.vehicle.coordinate) {
                    LiveVehicleMapPin(
                        vehicle: annotation.vehicle,
                        onTap: annotation.isTappable ? { openTrip(annotation) } : nil
                    )
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .onMapCameraChange(frequency: .onEnd) { context in
            let center = context.region.center
            mapCenter = center
            currentRegion = context.region

            guard hasBootstrapped else { return }
            scheduleReload(around: center)
        }
    }

    /// Contents of the floating pill over the map.
    @ViewBuilder
    private var headerPill: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pan the map to refresh stops around the center point.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.transitCaption)
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var sheetSections: some View {
        GTFSFeedWarningBanner(provider: provider)

        if let statusMessage, !statusMessage.isEmpty {
            MapInfoBanner(
                title: statusMessage,
                detail: statusDetail,
                icon: "clock.badge.checkmark"
            )
        }

        if let progressStage, !progressStage.isEmpty {
            MapInfoBanner(
                title: progressStage,
                detail: progressDetail,
                icon: "arrow.triangle.2.circlepath"
            )
        }

        routeSearchField

        // Both cards raise their trip selection to this view, so the whole
        // subtree presents from one `.sheet` rather than three competing ones.
        BusCard(
            title: nearbyCardTitle,
            busInfo: displayedNearbyBusInfo,
            selectedStopID: $selectedStopID,
            selectedTrip: $selectedTripRequest,
            showsNearby: true,
            showsFavourites: false,
            emptyStateMessageOverride: nearbyEmptyStateMessage
        )

        if !favouriteBusInfo.favouriteStops.isEmpty {
            BusCard(
                title: "Favourite \(provider.stopsTitle)",
                busInfo: favouriteBusInfo,
                selectedTrip: $selectedTripRequest,
                showsNearby: false,
                showsFavourites: true
            )
        }
    }

    private var routeSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(palette.textSecondary)

            TextField("Search route number", text: $routeSearchText)
                .font(.transitBody)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.search)

            if isRouteSearchActive {
                Button {
                    routeSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear route search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(palette.surfaceRaised.opacity(0.86), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(0.16), lineWidth: 1)
        }
    }

    /// Victoria is served live by the PTV API and has no local schedule, so
    /// there is nothing to expire there.
    private func refreshFeedStatusIfNeeded() async {
        guard provider.region == .queensland else { return }
        try? await GTFSDatabase.shared.ensureReady()
        await GTFSFeedStatusStore.shared.refresh()
    }

    /// Live vehicles come from TransLink's GTFS-realtime VehiclePositions feed,
    /// which only covers Queensland.
    /// The two regions supply vehicles by different routes.
    ///
    /// Queensland has a separate network-wide GTFS-RT feed, fetched here and
    /// filtered to the viewport. Victoria attaches positions to the departures
    /// response, so they arrive already on `nearbyBusInfo` and only cover runs
    /// serving the stops in view — nothing extra to fetch.
    ///
    /// Victorian *trams* have none: PTV returns no position for any tram run.
    private func refreshLiveVehicles() async {
        guard provider == .queenslandTransLink else { return }
        guard let currentRegion else {
            if !liveVehicles.isEmpty { liveVehicles = [] }
            return
        }

        let vehicles = await QLDVehiclePositionService.shared.vehicles(
            rail: false,
            in: currentRegion
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            liveVehicles = vehicles
        }
    }

    /// Queensland's viewport feed, or Victoria's board-attached positions.
    private var displayedVehicles: [LiveVehicle] {
        provider == .queenslandTransLink ? liveVehicles : nearbyBusInfo.liveVehicles
    }

    /// Vehicles paired with the board departure each is working.
    ///
    /// Not every vehicle resolves: Queensland's feed is network-wide, so it
    /// includes trips that call at no stop in view. Those pins stay
    /// non-interactive rather than giving a tap that does nothing.
    private var vehicleAnnotations: [VehicleAnnotation] {
        displayedVehicles.annotations(
            matching: displayedNearbyStops + favouriteBusInfo.favouriteStops
        )
    }

    private func openTrip(_ annotation: VehicleAnnotation) {
        guard let stopId = annotation.stopId, let departure = annotation.departure else { return }
        selectedTripRequest = BusTripRequest(
            provider: provider,
            stopId: stopId,
            departure: departure
        )
    }

    private func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        await refreshFeedStatusIfNeeded()

        if let initialBusInfo {
            selectedStopID = initialBusInfo.nearbyStops.first?.id
        }

        do {
            let location = try await LocationManager().currentLocation()
            let coordinate = location.coordinate
            userCoordinate = coordinate
            mapCenter = coordinate
            let initialRegion = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            cameraPosition = .region(initialRegion)
            currentRegion = initialRegion
            await reloadBoard(around: coordinate)
            await refreshLiveVehicles()
        } catch {
            if error is LocationError {
                let unavailable = BusInfo.noLocation(provider: provider)
                nearbyBusInfo = unavailable
                favouriteBusInfo = unavailable
                errorMessage = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recenterOnUser() {
        Task {
            do {
                let location = try await LocationManager().currentLocation()
                let coordinate = location.coordinate
                userCoordinate = coordinate
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            } catch {
                cameraPosition = .userLocation(fallback: .automatic)
            }
        }
    }

    @MainActor
    private func refreshAll() async {
        await onRefresh()

        if let coordinate = mapCenter ?? lastQueriedCenter ?? userCoordinate {
            await reloadBoard(around: coordinate)
        }
        await refreshLiveVehicles()
    }

    private func scheduleReload(around coordinate: CLLocationCoordinate2D) {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            if let lastQueriedCenter, coordinate.distance(to: lastQueriedCenter) < 45 {
                return
            }

            await reloadBoard(around: coordinate)
        }
    }

    private func runAutoRefreshLoop() async {
        guard autoRefreshEnabled else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: Self.autoRefreshInterval)
            guard !Task.isCancelled, autoRefreshEnabled else { return }
            await refreshAll()
        }
    }

    @MainActor
    private func reloadBoard(around coordinate: CLLocationCoordinate2D) async {
        isLoading = true
        errorMessage = nil
        let shouldAutoSelectFirstStop = lastQueriedCenter == nil

        do {
            let updatedBusInfo = try await providerService.fetchBusInfo(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )

            nearbyBusInfo = updatedBusInfo
            lastQueriedCenter = coordinate

            if let userCoordinate {
                favouriteBusInfo = try await fetchFavouriteBoard(
                    referenceLatitude: userCoordinate.latitude,
                    longitude: userCoordinate.longitude
                )
            } else {
                favouriteBusInfo = BusInfo(
                    provider: provider,
                    nearbyStops: [],
                    favouriteStops: [],
                    alerts: [],
                    localTimeAtFetch: updatedBusInfo.localTimeAtFetch,
                    locationAvailable: updatedBusInfo.locationAvailable
                )
            }

            let matchingStops = filteredNearbyStops(
                from: updatedBusInfo.nearbyStops,
                query: normalizedRouteSearchText
            )
            let matchingStopIDs = Set(matchingStops.map(\.id))

            if let selectedStopID, matchingStopIDs.contains(selectedStopID) {
                self.selectedStopID = selectedStopID
            } else if shouldAutoSelectFirstStop || isRouteSearchActive {
                selectedStopID = matchingStops.first?.id
            } else {
                selectedStopID = nil
            }
        } catch {
            if error is LocationError {
                let unavailable = BusInfo.noLocation(provider: provider)
                nearbyBusInfo = unavailable
                favouriteBusInfo = unavailable
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private var providerService: any BusDataProviding {
        switch provider {
        case .queenslandTransLink:
            return BusService.shared
        case .queenslandTrainTransLink:
            return QLDTrainMapService.shared
        case .victorianPTV:
            return PTVBoardService.victorianBus
        case .victorianTrainPTV:
            return PTVBoardService.victorianTrain
        case .victorianTramPTV:
            return PTVBoardService.victorianTram
        }
    }

    private func fetchFavouriteBoard(referenceLatitude latitude: Double, longitude: Double) async throws -> BusInfo {
        switch provider {
        case .queenslandTransLink:
            return try await BusService.shared.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        case .queenslandTrainTransLink:
            return try await QLDTrainMapService.shared.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        case .victorianPTV:
            return try await PTVBoardService.victorianBus.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        case .victorianTrainPTV:
            return try await PTVBoardService.victorianTrain.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        case .victorianTramPTV:
            return try await PTVBoardService.victorianTram.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        }
    }

    private func filteredNearbyStops(from stops: [NearbyBusStop], query: String) -> [NearbyBusStop] {
        guard !query.isEmpty else { return stops }

        return stops.compactMap { stop in
            let matchingDepartures = stop.departures.filter { departure in
                routeMatches(departure: departure, query: query)
            }

            guard !matchingDepartures.isEmpty else { return nil }

            return NearbyBusStop(
                id: stop.id,
                stopName: stop.stopName,
                stopCode: stop.stopCode,
                latitude: stop.latitude,
                longitude: stop.longitude,
                distanceMeters: stop.distanceMeters,
                departures: matchingDepartures,
                departureDataAvailability: stop.departureDataAvailability
            )
        }
    }

    private func routeMatches(departure: BusDeparture, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }

        return departure.routeShortName.localizedCaseInsensitiveContains(normalizedQuery)
            || departure.routeLongName.localizedCaseInsensitiveContains(normalizedQuery)
            || (departure.headsign?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
    }

    private func synchronizeSelectedStopWithDisplayedStops() {
        if let selectedStopID, displayedNearbyStopIDs.contains(selectedStopID) {
            return
        }

        selectedStopID = displayedNearbyStops.first?.id
    }
}

private struct BusStopMapPin: View {
    let stop: NearbyBusStop
    let isSelected: Bool
    let accentColor: Color
    let symbolName: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isSelected ? accentColor : Color.white)
                    .frame(width: isSelected ? 36 : 30, height: isSelected ? 36 : 30)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)

                Image(systemName: symbolName)
                    .font(.system(size: isSelected ? 15 : 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : accentColor)
            }

            if isSelected {
                Text(stop.stopName)
                    .font(.caption2.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }
}

private extension NearbyBusStop {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension CLLocationCoordinate2D {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}
