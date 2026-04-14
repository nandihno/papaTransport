import CoreLocation
import MapKit
import SwiftUI

struct TrainMapExplorerView: View {
    let initialBusInfo: BusInfo?
    let trainInfo: TrainInfo
    let onOpenSettings: () -> Void
    let onRefresh: () async -> Void

    @Environment(\.themePalette) private var palette

    @State private var nearbyInfo: BusInfo
    @State private var favouriteInfo: BusInfo
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedStopID: String?
    @State private var currentRegion: MKCoordinateRegion?
    @State private var lastQueriedRegion: MKCoordinateRegion?
    @State private var userCoordinate: CLLocationCoordinate2D?
    @State private var reloadTask: Task<Void, Never>?
    @State private var hasBootstrapped = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let provider: BusProvider = .victorianTrainPTV

    init(
        initialBusInfo: BusInfo? = nil,
        trainInfo: TrainInfo = .placeholder(lineName: "", homeStation: "", cityStation: ""),
        onOpenSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {}
    ) {
        self.initialBusInfo = initialBusInfo
        self.trainInfo = trainInfo
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        let seed = initialBusInfo ?? .placeholder(provider: .victorianTrainPTV)
        _nearbyInfo = State(initialValue: seed)
        _favouriteInfo = State(initialValue: seed)
    }

    private var mapSummary: String {
        let count = nearbyInfo.nearbyStops.count
        let label = count == 1 ? "station" : "stations"
        return "\(count) \(label) in view"
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    mapCard
                        .ignoresSafeArea(edges: .top)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.34),
                            Color.black.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)

                    headerOverlay(topInset: proxy.safeAreaInsets.top)
                }
                .frame(height: max(320, proxy.size.height * 0.46))

                bottomOverlay(bottomInset: proxy.safeAreaInsets.bottom)
            }
        }
        .background(Color.black)
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

            ForEach(nearbyInfo.nearbyStops) { stop in
                Annotation(stop.stopName, coordinate: stop.coordinate, anchor: .bottom) {
                    TrainStopMapPin(
                        stop: stop,
                        isSelected: selectedStopID == stop.id,
                        accentColor: palette.accent
                    )
                }
                .tag(stop.id)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            currentRegion = region

            guard hasBootstrapped else { return }
            scheduleReload(for: region)
        }
    }

    @ViewBuilder
    private func headerOverlay(topInset: CGFloat) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Trains")
                    .font(.transit(34, weight: .bold))
                    .foregroundStyle(Color.white)

                HStack(spacing: 8) {
                    Label(mapSummary, systemImage: "tram.fill")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.96))

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.82)
                            .tint(.white)
                    }
                }

                Text("Pan or zoom to refresh stations visible in the current area.")
                    .font(.transit(11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                }
            }

            Spacer()

            VStack(spacing: 16) {
                overlayControlButton(systemName: "gearshape.fill", action: onOpenSettings)
                overlayControlButton(systemName: "location.fill", action: recenterOnUser)
            }
        }
        .padding(.top, max(topInset, 12))
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func bottomOverlay(bottomInset: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                TrainStatusSummaryCard(train: trainInfo)

                BusCard(
                    title: "Nearby Train Stations",
                    busInfo: nearbyInfo,
                    selectedStopID: $selectedStopID,
                    showsNearby: true,
                    showsFavourites: false
                )

                if !favouriteInfo.favouriteStops.isEmpty {
                    BusCard(
                        title: "Favourite Train Stations",
                        busInfo: favouriteInfo,
                        showsNearby: false,
                        showsFavourites: true
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, max(bottomInset, 16))
        }
        .refreshable {
            await refreshAll()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func overlayControlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 56, height: 56)
                .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
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
            let region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
            currentRegion = region
            cameraPosition = .region(region)
            await reloadBoard(for: region)
        } catch {
            if error is LocationError {
                let unavailable = BusInfo.noLocation(provider: provider)
                nearbyInfo = unavailable
                favouriteInfo = unavailable
                errorMessage = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recenterOnUser() {
        guard let coordinate = userCoordinate else {
            cameraPosition = .userLocation(fallback: .automatic)
            return
        }

        let region = MKCoordinateRegion(
            center: coordinate,
            span: currentRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        currentRegion = region
        cameraPosition = .region(region)
    }

    @MainActor
    private func refreshAll() async {
        await onRefresh()

        if let region = currentRegion ?? lastQueriedRegion {
            await reloadBoard(for: region)
        }
    }

    private func scheduleReload(for region: MKCoordinateRegion) {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            if let lastQueriedRegion, !hasRegionChangedMeaningfully(region, comparedTo: lastQueriedRegion) {
                return
            }

            await reloadBoard(for: region)
        }
    }

    @MainActor
    private func reloadBoard(for region: MKCoordinateRegion) async {
        isLoading = true
        errorMessage = nil
        let shouldAutoSelectFirstStop = lastQueriedRegion == nil

        do {
            let updatedInfo = try await VictorianTrainMapService.shared.fetchBusInfo(
                minLat: region.center.latitude - region.span.latitudeDelta / 2,
                maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                minLon: region.center.longitude - region.span.longitudeDelta / 2,
                maxLon: region.center.longitude + region.span.longitudeDelta / 2,
                referenceLatitude: region.center.latitude,
                referenceLongitude: region.center.longitude
            )

            nearbyInfo = updatedInfo
            lastQueriedRegion = region

            if let userCoordinate {
                favouriteInfo = try await VictorianTrainMapService.shared.fetchFavouriteBusInfo(
                    referenceLatitude: userCoordinate.latitude,
                    longitude: userCoordinate.longitude
                )
            } else {
                favouriteInfo = BusInfo(
                    provider: provider,
                    nearbyStops: [],
                    favouriteStops: [],
                    alerts: [],
                    localTimeAtFetch: updatedInfo.localTimeAtFetch,
                    locationAvailable: updatedInfo.locationAvailable
                )
            }

            if let selectedStopID, updatedInfo.nearbyStops.contains(where: { $0.id == selectedStopID }) {
                self.selectedStopID = selectedStopID
            } else if shouldAutoSelectFirstStop {
                selectedStopID = updatedInfo.nearbyStops.first?.id
            } else {
                selectedStopID = nil
            }
        } catch {
            if error is LocationError {
                let unavailable = BusInfo.noLocation(provider: provider)
                nearbyInfo = unavailable
                favouriteInfo = unavailable
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func hasRegionChangedMeaningfully(
        _ region: MKCoordinateRegion,
        comparedTo previousRegion: MKCoordinateRegion
    ) -> Bool {
        let centerDistance = region.center.distance(to: previousRegion.center)
        let latitudeRatio = region.span.latitudeDelta / max(previousRegion.span.latitudeDelta, 0.0001)
        let longitudeRatio = region.span.longitudeDelta / max(previousRegion.span.longitudeDelta, 0.0001)
        let spanChanged = abs(latitudeRatio - 1) > 0.12 || abs(longitudeRatio - 1) > 0.12
        return centerDistance >= 150 || spanChanged
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
            VStack(alignment: .leading, spacing: 10) {
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

                if !train.alerts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(train.alerts.prefix(2))) { alert in
                            TrainAlertRow(alert: alert)
                        }
                    }
                } else if !train.plannedWorks.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Planned Works")
                            .font(.transit(12, weight: .bold))
                            .foregroundStyle(palette.textSecondary)
                        ForEach(Array(train.plannedWorks.prefix(2))) { work in
                            Text(work.title)
                                .font(.transit(12, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Train Stop Map Pin

private struct TrainStopMapPin: View {
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
