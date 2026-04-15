import CoreLocation
import MapKit
import SwiftUI

private enum BusSheetDetent: CaseIterable {
    case collapsed
    case medium
    case expanded
}

struct BusMapExplorerView: View {
    let provider: BusProvider
    let initialBusInfo: BusInfo?
    let onOpenSettings: () -> Void
    let onRefresh: () async -> Void
    let statusMessage: String?
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
    @State private var sheetDetent: BusSheetDetent = .medium
    @State private var sheetDragTranslation: CGFloat = 0
    @State private var isDraggingSheet = false

    init(
        provider: BusProvider,
        initialBusInfo: BusInfo? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {},
        statusMessage: String? = nil,
        progressStage: String? = nil,
        progressDetail: String? = nil
    ) {
        self.provider = provider
        self.initialBusInfo = initialBusInfo
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.statusMessage = statusMessage
        self.progressStage = progressStage
        self.progressDetail = progressDetail
        let seed = initialBusInfo ?? .placeholder(provider: provider)
        _nearbyBusInfo = State(initialValue: seed)
        _favouriteBusInfo = State(initialValue: seed)
    }

    private var searchCenter: CLLocationCoordinate2D? {
        mapCenter ?? lastQueriedCenter
    }

    private var mapSummary: String {
        let count = nearbyBusInfo.nearbyStops.count
        let stopLabel = count == 1 ? "stop" : "stops"
        return "\(count) \(stopLabel) within 300m"
    }

    private var screenTitle: String {
        provider == .victorianTrainPTV ? "Trains" : "Bus"
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
    }

    private var mapCard: some View {
        Map(position: $cameraPosition, selection: $selectedStopID) {
            UserAnnotation()

            if let searchCenter {
                MapCircle(center: searchCenter, radius: 300)
                    .foregroundStyle(palette.accent.opacity(0.12))
                    .stroke(palette.accentStrong.opacity(0.28), lineWidth: 1.5)
            }

            ForEach(nearbyBusInfo.nearbyStops) { stop in
                Annotation(stop.stopName, coordinate: stop.coordinate, anchor: .bottom) {
                    BusStopMapPin(
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
            let center = context.region.center
            mapCenter = center

            guard hasBootstrapped else { return }
            scheduleReload(around: center)
        }
    }

    @ViewBuilder
    private func headerOverlay(topInset: CGFloat) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(mapSummary, systemImage: "mappin.and.ellipse")
                            .font(.transit(12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.96))

                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.82)
                                .tint(.white)
                        }
                    }

                    Text("Pan the map to refresh stops around the center point.")
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    private func mapInfoBanner(title: String, detail: String?, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.transit(12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func overlayControlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                VStack(alignment: .leading, spacing: 14) {
                    if let statusMessage, !statusMessage.isEmpty {
                        mapInfoBanner(
                            title: statusMessage,
                            detail: nil,
                            icon: "clock.badge.checkmark"
                        )
                    }

                    if let progressStage, !progressStage.isEmpty {
                        mapInfoBanner(
                            title: progressStage,
                            detail: progressDetail,
                            icon: "arrow.triangle.2.circlepath"
                        )
                    }

                    BusCard(
                        title: "Nearby Bus Stops",
                        busInfo: nearbyBusInfo,
                        selectedStopID: $selectedStopID,
                        showsNearby: true,
                        showsFavourites: false
                    )

                    if !favouriteBusInfo.favouriteStops.isEmpty {
                        BusCard(
                            title: "Favourite Bus Stops",
                            busInfo: favouriteBusInfo,
                            showsNearby: false,
                            showsFavourites: true
                        )
                    }
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
                                Color.black.opacity(0.38),
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
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .shadow(color: Color.black.opacity(0.24), radius: 24, y: -6)
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
                .fill(Color.white.opacity(0.36))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            HStack(alignment: .center) {
                Text("Nearby Bus Stops")
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(palette.accentStrong)

                Spacer()

                Text(mapSummary)
                    .font(.transit(11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 18)

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.horizontal, 18)
        }
    }

    private func currentSheetHeight(in proxy: GeometryProxy) -> CGFloat {
        let heights = sheetHeights(in: proxy)
        let baseHeight = heights[sheetDetent] ?? heights[.medium] ?? 360
        let adjustedHeight = baseHeight - sheetDragTranslation
        return min(max(adjustedHeight, heights[.collapsed] ?? adjustedHeight), heights[.expanded] ?? adjustedHeight)
    }

    private func sheetHeights(in proxy: GeometryProxy) -> [BusSheetDetent: CGFloat] {
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

                if let nearestDetent = BusSheetDetent.allCases.min(by: {
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

    private func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        if let initialBusInfo {
            selectedStopID = initialBusInfo.nearbyStops.first?.id
        }

        do {
            let location = try await LocationManager().currentLocation()
            let coordinate = location.coordinate
            userCoordinate = coordinate
            mapCenter = coordinate
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            )
            await reloadBoard(around: coordinate)
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

            if let selectedStopID, updatedBusInfo.nearbyStops.contains(where: { $0.id == selectedStopID }) {
                self.selectedStopID = selectedStopID
            } else if shouldAutoSelectFirstStop {
                selectedStopID = updatedBusInfo.nearbyStops.first?.id
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
        case .victorianPTV:
            return VictorianBusService.shared
        case .victorianTrainPTV:
            return VictorianTrainMapService.shared
        }
    }

    private func fetchFavouriteBoard(referenceLatitude latitude: Double, longitude: Double) async throws -> BusInfo {
        switch provider {
        case .queenslandTransLink:
            return try await BusService.shared.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        case .victorianPTV:
            return try await VictorianBusService.shared.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        case .victorianTrainPTV:
            return try await VictorianTrainMapService.shared.fetchFavouriteBusInfo(
                referenceLatitude: latitude,
                longitude: longitude
            )
        }
    }
}

private struct BusStopMapPin: View {
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

                Image(systemName: "bus.fill")
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
