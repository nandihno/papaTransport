import CoreLocation
import MapKit
import SwiftUI

struct TrainMapExplorerView: View {
    let initialBusInfo: BusInfo?
    let trainInfo: TrainInfo
    let onRefresh: () async -> Void
    let autoRefreshEnabled: Bool
    let statusMessage: String?
    let statusDetail: String?

    @AppStorage("trainPlannedWorksMinimized") private var isPlannedWorksMinimized = true
    @Environment(\.themePalette) private var palette

    @State private var nearbyInfo: BusInfo
    @State private var favouriteStops: [NearbyBusStop]
    @State private var selectedStopID: String?
    @State private var selectedTripRequest: TrainTripRequest?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var lastQueriedRegion: MKCoordinateRegion?
    @State private var userCoordinate: CLLocationCoordinate2D?
    @State private var reloadTask: Task<Void, Never>?
    @State private var boardReloadGeneration = 0
    @State private var requestedRegion: MKCoordinateRegion?
    @State private var hasBootstrapped = false
    @State private var isLoading = false
    @State private var currentRegion: MKCoordinateRegion?
    @State private var errorMessage: String?
    @State private var showAllPlannedWorks = false
    @State private var liveVehicles: [LiveVehicle] = []
    @State private var routeSelection = MapRouteSelection()
    @State private var sheetPresentation = MapSheetPresentation()

    private let provider: BusProvider
    private static let autoRefreshInterval: Duration = .seconds(60)

    init(
        provider: BusProvider = .victorianTrainPTV,
        initialBusInfo: BusInfo? = nil,
        trainInfo: TrainInfo = .placeholder(lineName: ""),
        onRefresh: @escaping () async -> Void = {},
        autoRefreshEnabled: Bool = true,
        statusMessage: String? = nil,
        statusDetail: String? = nil
    ) {
        self.provider = provider
        self.initialBusInfo = initialBusInfo
        self.trainInfo = trainInfo
        self.onRefresh = onRefresh
        self.autoRefreshEnabled = autoRefreshEnabled
        self.statusMessage = statusMessage
        self.statusDetail = statusDetail
        let seed = initialBusInfo ?? Self.emptyBoard(provider: provider)
        _nearbyInfo = State(initialValue: BusInfo(
            provider: provider,
            nearbyStops: seed.nearbyStops,
            favouriteStops: [],
            alerts: [],
            localTimeAtFetch: seed.localTimeAtFetch,
            locationAvailable: seed.locationAvailable
        ))
        _favouriteStops = State(initialValue: seed.favouriteStops)
    }

    private static func emptyBoard(provider: BusProvider = .victorianTrainPTV) -> BusInfo {
        BusInfo(
            provider: provider,
            nearbyStops: [],
            favouriteStops: [],
            alerts: [],
            localTimeAtFetch: "--:-- --",
            locationAvailable: true
        )
    }

    private var displayedPlannedWorks: [TrainPlannedWork] {
        showAllPlannedWorks ? trainInfo.plannedWorks : Array(trainInfo.plannedWorks.prefix(4))
    }

    private var displayedNearbyStops: [NearbyBusStop] {
        nearbyInfo.nearbyStops
    }

    private var displayedFavouriteStops: [NearbyBusStop] {
        favouriteStops
    }

    private var favouriteStopsOutsideNearby: [NearbyBusStop] {
        let nearbyIDs = Set(displayedNearbyStops.map(\.id))
        return displayedFavouriteStops.filter { !nearbyIDs.contains($0.id) }
    }

    private var mapStops: [NearbyBusStop] {
        (displayedNearbyStops + displayedFavouriteStops).uniqueStops
    }

    private var peekDeparture: MapPeekDeparture? {
        guard let next = mapStops.nextMapDeparture(selectedStopID: selectedStopID) else { return nil }
        return MapPeekDeparture(departure: next.departure, stopName: next.stop.stopName) {
            selectDeparture(next.departure, at: next.stop.id)
            sheetPresentation.showDepartures(at: next.stop.id)
        }
    }

    /// 50 km guard: ~0.45° of latitude ≈ 50 km. Longitude degrees vary by latitude
    /// but using the same threshold is a safe, simple approximation for SEQ.
    private static let maxSpanDegrees: Double = 0.45

    private var isZoomedOutTooFar: Bool {
        guard let region = currentRegion else { return false }
        return region.span.latitudeDelta > Self.maxSpanDegrees
            || region.span.longitudeDelta > Self.maxSpanDegrees
    }

    private var mapSummary: String {
        if isZoomedOutTooFar { return "Zoom in to see stations" }
        let count = displayedNearbyStops.count
        let noun = count == 1 ? "station" : "stations"
        return "\(count) \(noun) in view"
    }

    var body: some View {
        MapSheetScaffold(
            title: "Train Stations in View",
            summary: mapSummary,
            isLoading: isLoading,
            onRecenter: recenterOnUser,
            onRefresh: { await refreshAll() },
            presentation: sheetPresentation,
            departureListFocusID: selectedStopID,
            peekDeparture: peekDeparture
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
            boardReloadGeneration &+= 1
            requestedRegion = nil
            isLoading = false
        }
        .onChange(of: selectedStopID) { _, stopId in
            selectMapStop(stopId)
        }
        .onChange(of: nearbyInfo.id) { _, _ in
            routeSelection.reconcile(with: mapStops)
        }
        .onChange(of: displayedFavouriteStops.map { $0.departures.map(\.id) }) { _, _ in
            routeSelection.reconcile(with: mapStops)
        }
        .task(id: routeSelection.selection?.geometryID) {
            await routeSelection.load(using: routeService)
        }
        .sheet(item: $selectedTripRequest) { request in
            TrainTripDetailSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Contents of the floating pill over the map. Only map interaction state —
    /// the station count lives on the sheet's grip handle.
    @ViewBuilder
    private var headerPill: some View {
        VStack(alignment: .leading, spacing: 6) {
            if routeSelection.selection != nil {
                MapRouteSelectionControls(route: routeSelection, onShowDetails: showSelectedTrip)
            } else {
                Text(isZoomedOutTooFar
                 ? "Zoom in (within ~50 km) to load train stations."
                 : "Tap a station to see its departures. Pan to find other stations.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
            }

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
        if routeSelection.selection != nil {
            MapRouteSelectionControls(route: routeSelection, onShowDetails: showSelectedTrip)
        }
        GTFSFeedWarningBanner(provider: provider)

        if let statusMessage, !statusMessage.isEmpty {
            MapInfoBanner(
                title: statusMessage,
                detail: statusDetail,
                icon: "clock.badge.checkmark"
            )
        }

        if !trainInfo.lineName.isEmpty && provider != .queenslandTrainTransLink {
            TrainStatusSummaryCard(train: trainInfo)

            if !trainInfo.plannedWorks.isEmpty {
                TrainPlannedWorksBoard(
                    works: displayedPlannedWorks,
                    totalCount: trainInfo.plannedWorks.count,
                    showsAll: $showAllPlannedWorks,
                    isMinimized: $isPlannedWorksMinimized
                )
            }
        }

        if provider == .queenslandTrainTransLink {
            QLDTrainNetworkStatusCard(alerts: nearbyInfo.alerts)
        }

        nearestStationsList
    }

    private var mapCard: some View {
        let stops = mapStops
        let matchingStopIDs = routeSelection.matchingStopIDs(in: stops)
        return Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(routeSelection.paths.indices, id: \.self) { index in
                MapPolyline(coordinates: routeSelection.paths[index])
                    .stroke(palette.info, lineWidth: 5)
            }

            ForEach(stops) { stop in
                Annotation(stop.stopName, coordinate: stop.coordinate, anchor: .bottom) {
                    Button {
                        showStationDepartures(stop.id)
                    } label: {
                        TrainStationMapPin(
                            stop: stop,
                            isSelected: selectedStopID == stop.id,
                            accentColor: palette.accent
                        )
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(stop.stopName) station")
                    .accessibilityHint("Opens this station's departures.")
                    .opacity(routeSelection.selection == nil || matchingStopIDs.contains(stop.id) ? 1 : 0.4)
                }
            }

            ForEach(vehicleAnnotations) { annotation in
                Annotation("", coordinate: annotation.vehicle.coordinate) {
                    LiveVehicleMapPin(
                        vehicle: annotation.vehicle,
                        onTap: annotation.isTappable ? { openTrip(annotation) } : nil
                    )
                    .opacity(routeSelection.selection == nil || annotation.vehicle.tripId == routeSelection.selection?.departure.tripId ? 1 : 0.3)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            currentRegion = region

            guard hasBootstrapped else { return }

            let tooFar = region.span.latitudeDelta > TrainMapExplorerView.maxSpanDegrees
                      || region.span.longitudeDelta > TrainMapExplorerView.maxSpanDegrees
            if tooFar {
                reloadTask?.cancel()
                boardReloadGeneration &+= 1
                requestedRegion = nil
                isLoading = false
                nearbyInfo = Self.emptyBoard(provider: provider)
                return
            }

            scheduleReload(for: region)
        }
    }

    /// Flat, not a `CardContainer`. The sheet is already the container — nesting
    /// a card inside it produced four competing edge treatments and inset the
    /// text by ~60pt. See UIRevampPlan.md Phase 2 §2.5.
    ///
    /// The title and count that used to head this card now live only on the
    /// sheet's grip handle, directly above.
    @ViewBuilder
    private var nearestStationsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !nearbyInfo.locationAvailable {
                Label(
                    "Location unavailable. Enable Location Services to show train stations from the visible map area.",
                    systemImage: "location.slash.fill"
                )
                .font(.transitCaption)
                .foregroundStyle(palette.warning)
            } else if displayedNearbyStops.isEmpty && displayedFavouriteStops.isEmpty {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading station departures…")
                    }
                    .font(.transitBody)
                } else {
                    Label(
                        "No train stations were found in the visible map area, and no favourites currently have departures.",
                        systemImage: "tram.fill"
                    )
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
                }
            } else {
                if !displayedNearbyStops.isEmpty {
                    stationListSection(
                        title: "In View",
                        systemImage: "location.fill",
                        accentColor: palette.textSecondary,
                        stops: mapStops.filter { stop in displayedNearbyStops.contains { $0.id == stop.id } }
                    )
                }

                if !favouriteStopsOutsideNearby.isEmpty {
                    if !displayedNearbyStops.isEmpty {
                        Divider()
                    }

                    stationListSection(
                        title: "Favourites",
                        systemImage: "star.fill",
                        accentColor: palette.accentText,
                        stops: favouriteStopsOutsideNearby
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func stationListSection(
        title: String,
        systemImage: String,
        accentColor: Color,
        stops: [NearbyBusStop]
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.bold())
            .foregroundStyle(accentColor)

        ForEach(stops) { stop in
            TrainStationSection(
                stop: stop,
                isExpanded: selectedStopID == stop.id,
                selectedDeparture: routeSelection.selection,
                isRefreshing: isLoading,
                revealID: sheetPresentation.revealID
            ) {
                toggleSelection(for: stop.id)
            } onSelectDeparture: { departure in
                showDepartureDetails(departure, at: stop.id)
            }
            .id("stop:\(stop.id)")
        }
    }

    // MARK: - Service dispatch

    private func fetchRegionInfo(
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        reference: CLLocationCoordinate2D
    ) async throws -> BusInfo {
        switch provider {
        case .queenslandTrainTransLink:
            return try await QLDTrainMapService.shared.fetchBusInfo(
                minLat: bounds.minLat,
                maxLat: bounds.maxLat,
                minLon: bounds.minLon,
                maxLon: bounds.maxLon,
                referenceLatitude: reference.latitude,
                referenceLongitude: reference.longitude
            )
        default:
            return try await PTVBoardService.victorianTrain.fetchBusInfo(
                minLat: bounds.minLat,
                maxLat: bounds.maxLat,
                minLon: bounds.minLon,
                maxLon: bounds.maxLon,
                referenceLatitude: reference.latitude,
                referenceLongitude: reference.longitude
            )
        }
    }

    private func fetchFavouriteInfo(reference: CLLocationCoordinate2D) async throws -> BusInfo {
        switch provider {
        case .queenslandTrainTransLink:
            return try await QLDTrainMapService.shared.fetchFavouriteBusInfo(
                referenceLatitude: reference.latitude,
                longitude: reference.longitude
            )
        default:
            return try await PTVBoardService.victorianTrain.fetchFavouriteBusInfo(
                referenceLatitude: reference.latitude,
                longitude: reference.longitude
            )
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
    /// response, so they arrive already on `nearbyInfo` and only cover runs
    /// serving the stops in view — nothing extra to fetch.
    private func refreshLiveVehicles() async {
        guard provider == .queenslandTrainTransLink else { return }
        guard let currentRegion else {
            if !liveVehicles.isEmpty { liveVehicles = [] }
            return
        }

        let vehicles = await QLDVehiclePositionService.shared.vehicles(
            rail: true,
            in: currentRegion
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            liveVehicles = vehicles
        }
    }

    /// Queensland's viewport feed, or Victoria's board-attached positions.
    private var displayedVehicles: [LiveVehicle] {
        provider == .queenslandTrainTransLink ? liveVehicles : nearbyInfo.liveVehicles
    }

    /// Vehicles paired with the board departure each is working.
    ///
    /// Not every vehicle resolves: Queensland's feed is network-wide, so it
    /// includes trips that call at no station in view. Those pins stay
    /// non-interactive rather than giving a tap that does nothing.
    private var vehicleAnnotations: [VehicleAnnotation] {
        displayedVehicles.annotations(
            matching: displayedNearbyStops + displayedFavouriteStops
        )
    }

    private func openTrip(_ annotation: VehicleAnnotation) {
        guard let stopId = annotation.stopId, let departure = annotation.departure else { return }
        selectDeparture(departure, at: stopId)
    }

    private var routeService: any BusDataProviding {
        provider == .queenslandTrainTransLink ? QLDTrainMapService.shared : PTVBoardService.victorianTrain
    }

    private func selectDeparture(_ departure: BusDeparture, at stopId: String) {
        guard let stop = mapStops.first(where: { $0.id == stopId }) else { return }
        selectedStopID = stopId
        routeSelection.select(MapDepartureSelection(provider: provider, stopId: stopId,
                                                   stopName: stop.stopName, departure: departure))
    }

    private func showDepartureDetails(_ departure: BusDeparture, at stopId: String) {
        selectDeparture(departure, at: stopId)
        selectedTripRequest = TrainTripRequest(stopId: stopId, departure: departure, provider: provider)
    }

    private func selectMapStop(_ stopId: String?) {
        guard let stopId, let stop = mapStops.first(where: { $0.id == stopId }) else {
            routeSelection.clear()
            return
        }
        guard routeSelection.selection != nil else { return }
        guard routeSelection.selection?.stopId != stopId else { return }
        let departure = stop.departures.first { $0.tripId == routeSelection.selection?.departure.tripId }
        if let departure { selectDeparture(departure, at: stopId) }
        else { routeSelection.clear() }
    }

    private func showStationDepartures(_ stopId: String) {
        selectedStopID = stopId
        if routeSelection.selection?.stopId != stopId { routeSelection.clear() }
        sheetPresentation.showDepartures(at: stopId)
    }

    private func showSelectedTrip() {
        guard let selection = routeSelection.selection else { return }
        selectedTripRequest = TrainTripRequest(
            stopId: selection.stopId,
            departure: selection.departure,
            provider: provider
        )
    }

    private func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        await refreshFeedStatusIfNeeded()

        if let initialBusInfo {
            nearbyInfo = BusInfo(
                provider: provider,
                nearbyStops: initialBusInfo.nearbyStops,
                favouriteStops: [],
                alerts: [],
                localTimeAtFetch: initialBusInfo.localTimeAtFetch,
                locationAvailable: initialBusInfo.locationAvailable
            )
            favouriteStops = initialBusInfo.favouriteStops
            synchronizeSelection(
                with: initialBusInfo.nearbyStops.map(\.id) + initialBusInfo.favouriteStops.map(\.id)
            )
        }

        do {
            let location = try await LocationManager().currentLocation()
            let coordinate = location.coordinate
            userCoordinate = coordinate

            let initialRegion = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            cameraPosition = .region(initialRegion)
            currentRegion = initialRegion
            await reloadBoard(for: initialRegion)
            await refreshLiveVehicles()
        } catch {
            await MainActor.run {
                if error is LocationError {
                    nearbyInfo = .noLocation(provider: provider)
                    favouriteStops = []
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshAll() async {
        async let statusRefresh: Void = onRefresh()
        if let region = currentRegion ?? lastQueriedRegion,
           region.span.latitudeDelta <= Self.maxSpanDegrees,
           region.span.longitudeDelta <= Self.maxSpanDegrees {
            await reloadBoard(for: region)
        }
        await refreshLiveVehicles()
        await statusRefresh
    }

    private func scheduleReload(for region: MKCoordinateRegion) {
        // Hard guard: never query when the visible area exceeds ~50 km
        guard region.span.latitudeDelta <= Self.maxSpanDegrees,
              region.span.longitudeDelta <= Self.maxSpanDegrees else { return }

        if let reference = requestedRegion ?? lastQueriedRegion,
           !regionNeedsRefresh(region, comparedTo: reference) { return }

        reloadTask?.cancel()
        boardReloadGeneration &+= 1
        let generation = boardReloadGeneration
        requestedRegion = region
        isLoading = true
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, generation == boardReloadGeneration else { return }

            await reloadBoard(for: region)
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
    private func reloadBoard(for region: MKCoordinateRegion) async {
        guard !Task.isCancelled else { return }
        boardReloadGeneration &+= 1
        let generation = boardReloadGeneration
        requestedRegion = region
        isLoading = true
        errorMessage = nil
        defer {
            if generation == boardReloadGeneration {
                isLoading = false
                requestedRegion = nil
            }
        }

        do {
            let reference = try await referenceCoordinate()
            guard !Task.isCancelled, generation == boardReloadGeneration else { return }
            let bounds = regionBounds(for: region)

            async let regionInfoTask = fetchRegionInfo(bounds: bounds, reference: reference)
            async let favouriteInfoTask = fetchFavouriteInfo(reference: reference)

            let updatedInfo = try await regionInfoTask
            guard !Task.isCancelled, generation == boardReloadGeneration else { return }

            nearbyInfo = updatedInfo
            lastQueriedRegion = region
            synchronizeSelection(
                with: updatedInfo.nearbyStops.map(\.id) + favouriteStops.map(\.id)
            )

            let favouriteInfo = try await favouriteInfoTask
            guard !Task.isCancelled, generation == boardReloadGeneration else { return }
            favouriteStops = favouriteInfo.favouriteStops
            synchronizeSelection(
                with: updatedInfo.nearbyStops.map(\.id) + favouriteStops.map(\.id)
            )
        } catch {
            guard !Task.isCancelled, generation == boardReloadGeneration else { return }
            if error is LocationError {
                nearbyInfo = .noLocation(provider: provider)
                favouriteStops = []
            }
            errorMessage = error.localizedDescription
        }
    }

    private func recenterOnUser() {
        Task {
            do {
                let location = try await LocationManager().currentLocation()
                let coordinate = location.coordinate
                userCoordinate = coordinate
                let region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                cameraPosition = .region(region)
            } catch {
                cameraPosition = .userLocation(fallback: .automatic)
            }
        }
    }

    private func toggleSelection(for stopID: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedStopID = selectedStopID == stopID ? nil : stopID
        }
    }

    private func synchronizeSelection(with stopIDs: [String]) {
        guard !stopIDs.isEmpty else {
            selectedStopID = nil
            return
        }

        if let selectedStopID, stopIDs.contains(selectedStopID) {
            return
        }

        selectedStopID = stopIDs.first
    }

    private func referenceCoordinate() async throws -> CLLocationCoordinate2D {
        if let userCoordinate {
            return userCoordinate
        }

        let location = try await LocationManager().currentLocation()
        let coordinate = location.coordinate
        await MainActor.run {
            userCoordinate = coordinate
        }
        return coordinate
    }

    private func regionBounds(for region: MKCoordinateRegion) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (
            minLat: region.center.latitude - region.span.latitudeDelta / 2,
            maxLat: region.center.latitude + region.span.latitudeDelta / 2,
            minLon: region.center.longitude - region.span.longitudeDelta / 2,
            maxLon: region.center.longitude + region.span.longitudeDelta / 2
        )
    }

    private func regionNeedsRefresh(_ region: MKCoordinateRegion, comparedTo previous: MKCoordinateRegion) -> Bool {
        let centerDistance = region.center.distance(to: previous.center)
        let latChange = abs(region.span.latitudeDelta - previous.span.latitudeDelta)
        let lonChange = abs(region.span.longitudeDelta - previous.span.longitudeDelta)

        return centerDistance > 120 || latChange > 0.003 || lonChange > 0.003
    }
}

// MARK: - QLD Train Network Status Card

private struct QLDTrainNetworkStatusCard: View {
    let alerts: [BusAlert]

    @AppStorage("qldTrainNetworkStatusMinimized") private var isMinimized = false
    @Environment(\.themePalette) private var palette

    private var statusColor: Color {
        alerts.isEmpty ? palette.success : palette.warning
    }

    private var statusIcon: String {
        alerts.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusLabel: String {
        if alerts.isEmpty { return "No active disruptions reported." }
        return alerts.count == 1 ? "1 active disruption" : "\(alerts.count) active disruptions"
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Train Network Status", systemImage: "tram.fill")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.accentText)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isMinimized.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(palette.surfaceRaised, in: Circle())
                            .rotationEffect(.degrees(isMinimized ? -90 : 0))
                    }
                    .buttonStyle(.plain)
                }

                if !isMinimized {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(statusLabel)
                            .font(.transitLabel)
                            .foregroundStyle(alerts.isEmpty ? palette.success : palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !alerts.isEmpty {
                        Divider()
                        ForEach(alerts) { alert in
                            BusAlertRow(alert: alert)
                        }
                    }
                }
            }
        }
    }
}

private struct TrainStatusSummaryCard: View {
    let train: TrainInfo

    @Environment(\.themePalette) private var palette

    private var statusColor: Color {
        train.serviceIsGood ? palette.success : palette.warning
    }

    private var secondarySummary: String? {
        if !train.alerts.isEmpty {
            let count = train.alerts.count
            return count == 1 ? "1 live disruption" : "\(count) live disruptions"
        }
        if !train.plannedWorks.isEmpty {
            let count = train.plannedWorks.count
            return count == 1 ? "1 planned works notice" : "\(count) planned works notices"
        }
        return nil
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Train Line Status", systemImage: "tram.fill")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.accentText)
                    Spacer()
                    Text(train.melbourneTimeAtFetch)
                        .font(.transitBadge)
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.surfaceRaised, in: Capsule())
                }

                Text(train.lineName)
                    .font(.transitTitle)
                    .foregroundStyle(palette.textPrimary)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: train.serviceIsGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(statusColor)
                    Text(train.serviceStatusMessage)
                        .font(.transitLabel)
                        .foregroundStyle(train.serviceIsGood ? palette.success : palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let secondarySummary {
                    Text(secondarySummary)
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }
}

private struct TrainPlannedWorksBoard: View {
    let works: [TrainPlannedWork]
    let totalCount: Int
    @Binding var showsAll: Bool
    @Binding var isMinimized: Bool

    @Environment(\.themePalette) private var palette

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Planned Works (\(totalCount))", systemImage: "wrench.and.screwdriver.fill")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    HStack(spacing: 8) {
                        if !isMinimized, totalCount > works.count {
                            Button("Show all") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showsAll = true
                                }
                            }
                            .font(.caption.bold())
                        } else if !isMinimized, showsAll && totalCount > 4 {
                            Button("Show less") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showsAll = false
                                }
                            }
                            .font(.caption.bold())
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isMinimized.toggle()
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption.bold())
                                .foregroundStyle(palette.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(palette.surfaceRaised, in: Circle())
                                .rotationEffect(.degrees(isMinimized ? -90 : 0))
                        }
                    }
                }

                if !isMinimized {
                    ForEach(works) { work in
                        TrainPlannedWorkRow(work: work)
                    }
                }
            }
        }
    }
}

private struct TrainStationSection: View {
    let stop: NearbyBusStop
    let isExpanded: Bool
    let selectedDeparture: MapDepartureSelection?
    let isRefreshing: Bool
    let revealID: UUID
    let onToggleExpanded: () -> Void
    let onSelectDeparture: (BusDeparture) -> Void

    @Environment(\.themePalette) private var palette
    @State private var collapsedDirectionLabels: Set<String> = []

    private var directionGroups: [DepartureDirectionGroup] {
        stop.departures.groupedByDirection()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggleExpanded) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stop.stopName)
                            .font(.transitHeadline)
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.leading)

                        Text("\(stop.departures.count) departures · next 2 hours")
                            .font(.transitCaption)
                            .foregroundStyle(palette.textSecondary)

                        if let code = stop.stopCode, !code.isEmpty {
                            Text("Station #\(code)")
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 10) {
                        Text(formattedStopDistance(stop.distanceMeters))
                            .font(.transitBadge)
                            .foregroundStyle(isExpanded ? palette.buttonForeground : palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isExpanded ? palette.accent : palette.surfaceRaised, in: Capsule())

                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(palette.textSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                if isRefreshing {
                    HStack {
                        ProgressView()
                        Text(directionGroups.isEmpty ? "Loading departures…" : "Updating departures…")
                    }
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
                }

                if directionGroups.isEmpty {
                    if !isRefreshing && stop.departureDataAvailability == .unavailable {
                        Label(
                            "Cached station location shown. Departures are unavailable until a connection returns.",
                            systemImage: "wifi.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                    } else if !isRefreshing {
                        Text("No departures found for this station within \("next 2 hours").")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary)
                            .italic()
                    }
                } else {
                    ForEach(directionGroups) { group in
                        DepartureGroupSection(
                            group: group,
                            isExpanded: !collapsedDirectionLabels.contains(group.id),
                            selectedDeparture: selectedDeparture,
                            stopId: stop.id
                        ) {
                            toggleDirection(group.id)
                        } onSelectDeparture: { departure in
                            onSelectDeparture(departure)
                        }
                    }
                }
            }
        }
        // Selected rows get a tint; unselected ones sit flat on the sheet with
        // only a hairline separating them. Previously every row carried its own
        // border, which read as boxes inside boxes inside the sheet.
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(
            isExpanded ? palette.surfaceRaised.opacity(0.55) : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            if !isExpanded {
                Rectangle()
                    .fill(palette.textTertiary.opacity(0.14))
                    .frame(height: 1)
            }
        }
        .onChange(of: directionGroups.map(\.id), initial: true) { _, ids in
            collapsedDirectionLabels = Set(ids)
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { collapseAllDirections() }
        }
        .onChange(of: revealID) { _, _ in
            if isExpanded { collapseAllDirections() }
        }
    }

    private func toggleDirection(_ label: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedDirectionLabels.contains(label) {
                collapsedDirectionLabels.remove(label)
            } else {
                collapsedDirectionLabels.insert(label)
            }
        }
    }

    private func collapseAllDirections() {
        collapsedDirectionLabels = Set(directionGroups.map(\.id))
    }
}

private struct TrainTripRequest: Identifiable {
    let stopId: String
    let departure: BusDeparture
    let provider: BusProvider

    var id: String { "\(departure.tripId):\(stopId):\(departure.stopSequence)" }
}

private struct TrainTripDetailSheet: View {
    let request: TrainTripRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var tripDetail: BusTripDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isStopsExpanded = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading train stops…")
                            .font(.subheadline)
                            .foregroundStyle(palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let tripDetail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            summaryCard(tripDetail)
                            stopsCard(tripDetail)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Train Detail Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "This train trip pattern could not be loaded.")
                    )
                }
            }
            .navigationTitle(request.departure.routeShortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: request.id) {
            isStopsExpanded = false
            await loadTripDetail()
        }
    }

    @ViewBuilder
    private func summaryCard(_ tripDetail: BusTripDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(request.departure.routeShortName)
                    .font(.transitTitle.monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.84))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(tripDetail.headsign ?? tripDetail.routeLongName)
                        .font(.transitHeadline)
                        .foregroundStyle(palette.textPrimary)
                    Text(tripDetail.routeLongName)
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)

                    // Victoria only — PTV names the rolling stock, TransLink
                    // publishes no equivalent.
                    if let vehicle = tripDetail.vehicleDescription {
                        Label(vehicle, systemImage: "train.side.front.car")
                            .font(.transitBadge)
                            .foregroundStyle(palette.textTertiary)
                            .padding(.top, 2)
                    }
                }
            }

            trainMetric(
                title: "Selected Station",
                value: tripDetail.selectedStopName,
                secondary: selectedStationSecondary(tripDetail)
            )

            trainMetric(
                title: "Trip Continues",
                value: "\(tripDetail.remainingStopCount) more stops",
                secondary: tripDetail.earlierStopCount > 0
                    ? "Started \(tripDetail.earlierStopCount) stops earlier"
                    : "This is the first stop"
            )

            trainMetric(
                title: "Final Destination",
                value: tripDetail.terminalStopName,
                secondary: terminalSecondaryText(tripDetail)
            )
        }
        .padding(16)
        .background(palette.mutedPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func stopsCard(_ tripDetail: BusTripDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isStopsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Stops From Here")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Text(isStopsExpanded ? "Hide stops" : "Show stops")
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                    Image(systemName: isStopsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isStopsExpanded ? "Hide stops from here" : "Show stops from here")

            if isStopsExpanded {
                ForEach(Array(tripDetail.stopsFromSelected.enumerated()), id: \.element.id) { index, stop in
                    TripStopRow(
                        stop: stop,
                        isLast: index == tripDetail.stopsFromSelected.count - 1
                    )
                }
            }
        }
        .padding(16)
        .background(palette.mutedPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func trainMetric(title: String, value: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(palette.textSecondary)
            Text(value)
                .font(.transitBody)
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(palette.surfaceRaised.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func terminalSecondaryText(_ tripDetail: BusTripDetail) -> String {
        if let terminalScheduledTime = tripDetail.terminalScheduledTime,
           let terminalPredictedTime = tripDetail.terminalPredictedTime {
            return "Scheduled \(terminalScheduledTime) • Predicted \(terminalPredictedTime)"
        }
        if let terminalScheduledTime = tripDetail.terminalScheduledTime {
            return "Scheduled \(terminalScheduledTime)"
        }
        if let terminalPredictedTime = tripDetail.terminalPredictedTime {
            return "Predicted \(terminalPredictedTime)"
        }
        return "Arrival time unavailable"
    }

    private func selectedStationSecondary(_ tripDetail: BusTripDetail) -> String {
        let stopSequence = "Stop sequence \(tripDetail.selectedStopSequence)"
        let platform = request.departure.platform?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let platform, !platform.isEmpty else { return stopSequence }
        return "Platform \(platform) • \(stopSequence)"
    }

    private func loadTripDetail() async {
        isLoading = true
        errorMessage = nil
        tripDetail = nil

        do {
            tripDetail = try await trainMapService(for: request.provider).fetchTripDetail(
                for: request.departure,
                stopId: request.stopId
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private func trainMapService(for provider: BusProvider) -> any BusDataProviding {
    switch provider {
    case .queenslandTrainTransLink:
        return QLDTrainMapService.shared
    default:
        return PTVBoardService.victorianTrain
    }
}

private struct TrainStationMapPin: View {
    let stop: NearbyBusStop
    let isSelected: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isSelected ? accentColor : Color.white)
                    .frame(width: isSelected ? 36 : 30, height: isSelected ? 36 : 30)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)

                Image(systemName: "tram.fill")
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
