import CoreLocation
import MapKit
import SwiftUI

private enum TrainSheetDetent: CaseIterable {
    case collapsed
    case medium
    case expanded
}

struct TrainMapExplorerView: View {
    let initialBusInfo: BusInfo?
    let trainInfo: TrainInfo
    let onOpenSettings: () -> Void
    let onRefresh: () async -> Void

    @AppStorage("trainNearestStationsMinimized") private var isNearestStationsMinimized = false
    @AppStorage("trainPlannedWorksMinimized") private var isPlannedWorksMinimized = false
    @Environment(\.themePalette) private var palette

    @State private var nearbyInfo: BusInfo
    @State private var favouriteStops: [NearbyBusStop]
    @State private var selectedStopID: String?
    @State private var selectedTripRequest: TrainTripRequest?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var lastQueriedRegion: MKCoordinateRegion?
    @State private var userCoordinate: CLLocationCoordinate2D?
    @State private var reloadTask: Task<Void, Never>?
    @State private var hasBootstrapped = false
    @State private var isLoading = false
    @State private var currentRegion: MKCoordinateRegion?
    @State private var errorMessage: String?
    @State private var userCoordinateDescription = "Visible area on the map"
    @State private var showAllPlannedWorks = false
    @State private var sheetDetent: TrainSheetDetent = .medium
    @State private var sheetDragTranslation: CGFloat = 0
    @State private var isDraggingSheet = false

    private let provider: BusProvider

    init(
        provider: BusProvider = .victorianTrainPTV,
        initialBusInfo: BusInfo? = nil,
        trainInfo: TrainInfo = .placeholder(lineName: "", homeStation: "", cityStation: ""),
        onOpenSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {}
    ) {
        self.provider = provider
        self.initialBusInfo = initialBusInfo
        self.trainInfo = trainInfo
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
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

    private var nearbyStationsLabel: String {
        let count = nearbyInfo.nearbyStops.count
        let noun = count == 1 ? "station" : "stations"
        return "\(count) \(noun) in view"
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
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                mapCard
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.44),
                        Color.black.opacity(0.14),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

                LinearGradient(
                    colors: [
                        Color.clear,
                        palette.backgroundBase.opacity(0.12),
                        palette.backgroundBase.opacity(0.58)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

                headerOverlay(topInset: proxy.safeAreaInsets.top)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bottomSheet(proxy: proxy)
                }
            }
        }
        .background(palette.backgroundBase)
        .task {
            await bootstrap()
        }
        .onDisappear {
            reloadTask?.cancel()
        }
        .sheet(item: $selectedTripRequest) { request in
            TrainTripDetailSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var mapCard: some View {
        Map(position: $cameraPosition, selection: $selectedStopID) {
            UserAnnotation()

            ForEach(displayedNearbyStops) { stop in
                Annotation(stop.stopName, coordinate: stop.coordinate, anchor: .bottom) {
                    TrainStationMapPin(
                        stop: stop,
                        isSelected: selectedStopID == stop.id,
                        accentColor: palette.accent
                    )
                }
                .tag(stop.id)
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
                nearbyInfo = Self.emptyBoard(provider: provider)
                return
            }

            scheduleReload(for: region)
        }
    }

    @ViewBuilder
    private func headerOverlay(topInset: CGFloat) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(mapSummary, systemImage: "tram.fill")
                            .font(.transit(12, weight: .bold))
                            .foregroundStyle(.primary)

                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.82)
                        }
                    }

                    Text(isZoomedOutTooFar
                         ? "Zoom in (within ~50 km) to load train stations."
                         : "Pan the map to load train stations in the visible area.")
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Spacer()

            VStack(spacing: 12) {
                overlayControlButton(systemName: "gearshape.fill", action: onOpenSettings)
                overlayControlButton(systemName: "location.fill", action: recenterOnUser)
            }
        }
        .padding(.top, max(topInset, 12))
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func overlayControlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bottomSheet(proxy: GeometryProxy) -> some View {
        let safeBottom = max(proxy.safeAreaInsets.bottom, 12)
        let height = currentSheetHeight(in: proxy)

        VStack(spacing: 0) {
            gripHandle
                .contentShape(Rectangle())
                .gesture(sheetDragGesture(in: proxy))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if !trainInfo.lineName.isEmpty {
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

                    nearestStationsCard
                }
                .padding(.horizontal, 10)
                .padding(.bottom, safeBottom + 10)
            }
            .refreshable {
                await refreshAll()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.surfaceOverlay.opacity(0.55),
                                palette.backgroundBase.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .shadow(color: Color.black.opacity(0.14), radius: 24, y: -6)
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.86), value: sheetDetent)
        .transaction { transaction in
            if isDraggingSheet {
                transaction.animation = nil
            }
        }
    }

    private var gripHandle: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(palette.textTertiary.opacity(0.5))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            HStack(alignment: .center) {
                Text("Train Stations in View")
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(palette.accentStrong)

                Spacer()

                Text(mapSummary)
                    .font(.transit(11, weight: .bold))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(palette.surfaceRaised.opacity(0.8), in: Capsule())
            }
            .padding(.horizontal, 18)

            Divider()
                .padding(.horizontal, 18)
        }
    }

    @ViewBuilder
    private var nearestStationsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Train Stations in View", systemImage: "location.circle.fill")
                            .font(.transit(18, weight: .bold))
                            .foregroundStyle(palette.accent)

                        Text(userCoordinateDescription)
                            .font(.transit(12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.9)
                        } else {
                            Text(nearbyStationsLabel)
                                .font(.transit(11, weight: .bold))
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(palette.surfaceRaised, in: Capsule())
                        }

                        minimizeButton(isMinimized: $isNearestStationsMinimized)
                    }
                }

                if !isNearestStationsMinimized {
                    if !nearbyInfo.locationAvailable {
                        Label(
                            "Location unavailable. Enable Location Services to show train stations from the visible map area.",
                            systemImage: "location.slash.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.warning)
                    } else if let errorMessage, !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.warning)
                    } else if displayedNearbyStops.isEmpty && displayedFavouriteStops.isEmpty {
                        Label(
                            "No train stations were found in the visible map area, and no favourites currently have departures.",
                            systemImage: "tram.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                    } else {
                        Text("Tap a station to expand live departures. Tap a departure to see the stops remaining on that service.")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary)

                        if !displayedNearbyStops.isEmpty {
                            stationListSection(
                                title: "In View",
                                systemImage: "location.fill",
                                accentColor: palette.textSecondary,
                                stops: displayedNearbyStops
                            )
                        }

                        if !displayedFavouriteStops.isEmpty {
                            if !displayedNearbyStops.isEmpty {
                                Divider()
                            }

                            stationListSection(
                                title: "Favourites",
                                systemImage: "star.fill",
                                accentColor: palette.accent,
                                stops: displayedFavouriteStops
                            )
                        }
                    }
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
                isExpanded: selectedStopID == stop.id
            ) {
                toggleSelection(for: stop.id)
            } onSelectDeparture: { departure in
                selectedTripRequest = TrainTripRequest(stopId: stop.id, departure: departure, provider: provider)
            }
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
            return try await VictorianTrainMapService.shared.fetchBusInfo(
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
            return try await VictorianTrainMapService.shared.fetchFavouriteBusInfo(
                referenceLatitude: reference.latitude,
                longitude: reference.longitude
            )
        }
    }

    private func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

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
            userCoordinateDescription = "Visible map area • distances from this device"

            let initialRegion = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            cameraPosition = .region(initialRegion)
            await reloadBoard(for: initialRegion)
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
        await onRefresh()
        if let lastQueriedRegion {
            await reloadBoard(for: lastQueriedRegion)
        }
    }

    private func scheduleReload(for region: MKCoordinateRegion) {
        // Hard guard: never query when the visible area exceeds ~50 km
        guard region.span.latitudeDelta <= Self.maxSpanDegrees,
              region.span.longitudeDelta <= Self.maxSpanDegrees else { return }

        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }

            if let lastQueriedRegion, !regionNeedsRefresh(region, comparedTo: lastQueriedRegion) {
                return
            }

            await reloadBoard(for: region)
        }
    }

    private func reloadBoard(for region: MKCoordinateRegion) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let reference = try await referenceCoordinate()
            let bounds = regionBounds(for: region)

            async let regionInfoTask = fetchRegionInfo(bounds: bounds, reference: reference)
            async let favouriteInfoTask = fetchFavouriteInfo(reference: reference)

            let updatedInfo = try await regionInfoTask
            let favouriteInfo = try await favouriteInfoTask

            await MainActor.run {
                nearbyInfo = updatedInfo
                favouriteStops = favouriteInfo.favouriteStops
                lastQueriedRegion = region
                userCoordinateDescription = "Visible map area • distances from this device"
                synchronizeSelection(
                    with: updatedInfo.nearbyStops.map(\.id) + favouriteInfo.favouriteStops.map(\.id)
                )
                isLoading = false
            }
        } catch {
            await MainActor.run {
                if error is LocationError {
                    nearbyInfo = .noLocation(provider: provider)
                    favouriteStops = []
                }
                errorMessage = error.localizedDescription
                isLoading = false
            }
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

    private func currentSheetHeight(in proxy: GeometryProxy) -> CGFloat {
        let heights = sheetHeights(in: proxy)
        let baseHeight = heights[sheetDetent] ?? heights[.medium] ?? 360
        let adjustedHeight = baseHeight - sheetDragTranslation
        return min(max(adjustedHeight, heights[.collapsed] ?? adjustedHeight), heights[.expanded] ?? adjustedHeight)
    }

    private func sheetHeights(in proxy: GeometryProxy) -> [TrainSheetDetent: CGFloat] {
        let safeTop = max(proxy.safeAreaInsets.top, 12)
        let safeBottom = max(proxy.safeAreaInsets.bottom, 12)
        let availableHeight = proxy.size.height - safeTop
        let collapsed = max(104, safeBottom + 92)
        let expanded = min(availableHeight - 18, proxy.size.height * 0.88)
        let medium = min(max(360, proxy.size.height * 0.47), expanded - 80)

        return [
            .collapsed: collapsed,
            .medium: max(collapsed + 60, medium),
            .expanded: max(medium + 80, expanded)
        ]
    }

    private func sheetDragGesture(in proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                isDraggingSheet = true
                sheetDragTranslation = value.translation.height
            }
            .onEnded { value in
                let heights = sheetHeights(in: proxy)
                let baseHeight = heights[sheetDetent] ?? heights[.medium] ?? 360
                let projectedHeight = min(
                    max(baseHeight - value.predictedEndTranslation.height, heights[.collapsed] ?? baseHeight),
                    heights[.expanded] ?? baseHeight
                )

                if let nearestDetent = TrainSheetDetent.allCases.min(by: {
                    abs((heights[$0] ?? projectedHeight) - projectedHeight) <
                    abs((heights[$1] ?? projectedHeight) - projectedHeight)
                }) {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.84)) {
                        sheetDetent = nearestDetent
                        sheetDragTranslation = 0
                        isDraggingSheet = false
                    }
                } else {
                    sheetDragTranslation = 0
                    isDraggingSheet = false
                }
            }
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

private struct TrainStatusSummaryCard: View {
    let train: TrainInfo

    @Environment(\.themePalette) private var palette

    private var statusColor: Color {
        train.serviceIsGood ? AppTheme.success : AppTheme.warning
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
                        .font(.transit(16, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Spacer()
                    Text(train.melbourneTimeAtFetch)
                        .font(.transit(11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.surfaceRaised, in: Capsule())
                }

                Text(train.lineName)
                    .font(.transit(24, weight: .heavy))
                    .foregroundStyle(palette.textPrimary)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: train.serviceIsGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(statusColor)
                    Text(train.serviceStatusMessage)
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(train.serviceIsGood ? AppTheme.success : palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let secondarySummary {
                    Text(secondarySummary)
                        .font(.transit(12, weight: .medium))
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
                        .font(.transit(16, weight: .bold))
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

private extension TrainMapExplorerView {
    @ViewBuilder
    func minimizeButton(isMinimized: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isMinimized.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.bold())
                .foregroundStyle(palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(palette.surfaceRaised, in: Circle())
                .rotationEffect(.degrees(isMinimized.wrappedValue ? -90 : 0))
        }
        .buttonStyle(.plain)
    }
}

private struct TrainStationSection: View {
    let stop: NearbyBusStop
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onSelectDeparture: (BusDeparture) -> Void

    @Environment(\.themePalette) private var palette
    @State private var expandedLineNames: Set<String> = []

    private var windowedDepartures: [BusDeparture] {
        stop.departures
            .sorted { lhs, rhs in
                let lhsLine = lineName(for: lhs)
                let rhsLine = lineName(for: rhs)

                let comparison = lhsLine.localizedCaseInsensitiveCompare(rhsLine)
                if comparison == .orderedSame {
                    return lhs.scheduledSeconds < rhs.scheduledSeconds
                }
                return comparison == .orderedAscending
            }
    }

    private var lineGroups: [TrainLineGroup] {
        let grouped = Dictionary(grouping: windowedDepartures, by: lineName(for:))

        return grouped
            .map { lineName, departures in
                TrainLineGroup(
                    lineName: lineName,
                    departures: departures.sorted { $0.scheduledSeconds < $1.scheduledSeconds }
                )
            }
            .sorted {
                $0.lineName.localizedCaseInsensitiveCompare($1.lineName) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggleExpanded) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stop.stopName)
                            .font(.transit(18, weight: .heavy))
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.leading)

                        if let code = stop.stopCode, !code.isEmpty {
                            Text("Station #\(code)")
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 10) {
                        Text("\(stop.distanceMeters)m away")
                            .font(.transit(11, weight: .bold))
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

                if lineGroups.isEmpty {
                    Text("No departures found for this station within \("next 2 hours").")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .italic()
                } else {
                    ForEach(lineGroups) { group in
                        TrainLineGroupSection(
                            group: group,
                            isExpanded: expandedLineNames.contains(group.id)
                        ) {
                            toggleLine(group.id)
                        } onSelectDeparture: { departure in
                            onSelectDeparture(departure)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(isExpanded ? palette.surfaceRaised.opacity(0.92) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isExpanded ? palette.accentStrong.opacity(0.36) : palette.textTertiary.opacity(0.08),
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                expandedLineNames.removeAll()
            }
        }
    }

    private func lineName(for departure: BusDeparture) -> String {
        let value = departure.routeShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Train" : value
    }

    private func toggleLine(_ lineName: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedLineNames.contains(lineName) {
                expandedLineNames.remove(lineName)
            } else {
                expandedLineNames.insert(lineName)
            }
        }
    }
}

private struct TrainLineGroup: Identifiable {
    let lineName: String
    let departures: [BusDeparture]

    var id: String { lineName }

    var nextDeparture: BusDeparture? {
        departures.first
    }
}

private struct TrainLineGroupSection: View {
    let group: TrainLineGroup
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onSelectDeparture: (BusDeparture) -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 12) {
                    Text(group.lineName)
                        .font(.transit(13, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.84))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(minWidth: 68, maxWidth: 92)
                        .background(palette.buttonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.nextDepartureTitle)
                            .font(.transit(15, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)

                        Text(group.secondarySummary)
                            .font(.transit(11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 2) {
                        if let nextDeparture = group.nextDeparture {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                let duration = nextDeparture.minutesAway.durationComponents
                                Text(duration.value)
                                    .font(.transit(26, weight: .heavy).monospacedDigit())
                                    .foregroundStyle(palette.textPrimary)
                                if !duration.unit.isEmpty {
                                    Text(duration.unit)
                                        .font(.transit(11, weight: .bold))
                                        .foregroundStyle(palette.textSecondary)
                                }
                            }
                        }

                        Text(group.departureCountLabel)
                            .font(.transit(11, weight: .bold))
                            .foregroundStyle(palette.textSecondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.departures) { departure in
                        TrainDepartureRow(departure: departure, showsRouteBadge: false) {
                            onSelectDeparture(departure)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

private extension TrainLineGroup {
    var nextDepartureTitle: String {
        guard let nextDeparture else { return lineName }
        let value = (nextDeparture.headsign ?? nextDeparture.routeLongName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? lineName : value
    }

    var secondarySummary: String {
        guard let nextDeparture else { return "No scheduled services" }
        let firstTime = "Next \(nextDeparture.scheduledTime)"
        return departures.count == 1
            ? "\(firstTime) • 1 service in \("next 2 hours")"
            : "\(firstTime) • \(departures.count) services in \("next 2 hours")"
    }

    var departureCountLabel: String {
        departures.count == 1 ? "1 service" : "\(departures.count) services"
    }
}

private struct TrainDepartureRow: View {
    let departure: BusDeparture
    let showsRouteBadge: Bool
    let onTap: () -> Void

    @Environment(\.themePalette) private var palette

    init(
        departure: BusDeparture,
        showsRouteBadge: Bool = true,
        onTap: @escaping () -> Void
    ) {
        self.departure = departure
        self.showsRouteBadge = showsRouteBadge
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                if showsRouteBadge {
                    Text(routeBadgeText)
                        .font(.transit(12, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.84))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(minWidth: 68, maxWidth: 92)
                        .background(palette.buttonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryTitle)
                        .font(.transit(15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("Sched \(departure.scheduledTime)")
                            .font(.transit(11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)

                        if let predictedTime = departure.predictedTime {
                            Text("Pred \(predictedTime)")
                                .font(.transit(11, weight: .bold))
                                .foregroundStyle(statusColor)
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        let duration = departure.minutesAway.durationComponents
                        Text(duration.value)
                            .font(.transit(28, weight: .heavy).monospacedDigit())
                            .foregroundStyle(palette.textPrimary)
                        if !duration.unit.isEmpty {
                            Text(duration.unit)
                                .font(.transit(11, weight: .bold))
                                .foregroundStyle(palette.textSecondary)
                        }
                    }

                    Text(departure.status.rawValue)
                        .font(.transit(11, weight: .bold))
                        .foregroundStyle(statusColor)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the stops remaining on this train service.")
    }

    private var routeBadgeText: String {
        let value = departure.routeShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Train" : value
    }

    private var primaryTitle: String {
        let value = (departure.headsign ?? departure.routeLongName).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Service details unavailable" : value
    }

    private var statusColor: Color {
        switch departure.status {
        case .onTime: return AppTheme.success
        case .early: return AppTheme.info
        case .late: return AppTheme.warning
        case .noData: return palette.textSecondary
        case .skipped: return AppTheme.danger
        }
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
            await loadTripDetail()
        }
    }

    @ViewBuilder
    private func summaryCard(_ tripDetail: BusTripDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(request.departure.routeShortName)
                    .font(.transit(22, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.84))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(tripDetail.headsign ?? tripDetail.routeLongName)
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(tripDetail.routeLongName)
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }
            }

            trainMetric(
                title: "Selected Station",
                value: tripDetail.selectedStopName,
                secondary: "Stop sequence \(tripDetail.selectedStopSequence)"
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
            Text("Stops From Here")
                .font(.transit(18, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            ForEach(Array(tripDetail.stopsFromSelected.enumerated()), id: \.element.id) { index, stop in
                VictorianTripStopRow(
                    stop: stop,
                    isLast: index == tripDetail.stopsFromSelected.count - 1
                )
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
                .font(.transit(15, weight: .bold))
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
        return VictorianTrainMapService.shared
    }
}

private struct VictorianTripStopRow: View {
    let stop: BusTripStopDetail
    let isLast: Bool

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(markerColor)
                    .frame(width: stop.isSelectedStop ? 12 : 9, height: stop.isSelectedStop ? 12 : 9)
                    .padding(.top, 4)

                if !isLast {
                    Rectangle()
                        .fill(palette.textTertiary.opacity(0.35))
                        .frame(width: 2, height: 28)
                        .padding(.top, 4)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stop.stopName)
                        .font(.transit(15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if stop.isSelectedStop {
                        Text("Selected")
                            .font(.caption2.bold())
                            .foregroundStyle(palette.buttonForeground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(palette.buttonBackground, in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    if let stopCode = stop.stopCode, !stopCode.isEmpty {
                        Text("Stop #\(stopCode)")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }

                    if let scheduledTime = stop.scheduledTime {
                        Text(scheduledTime)
                            .font(.caption.bold())
                            .foregroundStyle(stop.isSelectedStop ? palette.accent : palette.textSecondary)
                    }

                    if let predictedTime = stop.predictedTime {
                        Text("Pred \(predictedTime)")
                            .font(.caption.bold())
                            .foregroundStyle(statusColor)
                    }

                    if let status = stop.status {
                        Text(status.rawValue)
                            .font(.caption2.bold())
                            .foregroundStyle(statusColor)
                    }

                    if let delaySeconds = stop.delaySeconds,
                       let status = stop.status,
                       status != .noData,
                       status != .skipped,
                       delaySeconds != 0 {
                        let delayText = delaySeconds > 0 ? "+\(delaySeconds)s" : "\(delaySeconds)s"
                        Text(delayText)
                            .font(.caption2)
                            .foregroundStyle(statusColor)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var markerColor: Color {
        if stop.isSelectedStop {
            return palette.accent
        }
        if let status = stop.status {
            return color(for: status)
        }
        return palette.textTertiary.opacity(0.75)
    }

    private var statusColor: Color {
        guard let status = stop.status else { return palette.textSecondary }
        return color(for: status)
    }

    private func color(for status: BusDepartureStatus) -> Color {
        switch status {
        case .onTime: return AppTheme.success
        case .early: return AppTheme.info
        case .late: return AppTheme.warning
        case .noData: return palette.textSecondary
        case .skipped: return AppTheme.danger
        }
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
                    .background(.ultraThinMaterial, in: Capsule())
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
