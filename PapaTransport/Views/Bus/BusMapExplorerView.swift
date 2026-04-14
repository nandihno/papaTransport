import CoreLocation
import MapKit
import SwiftUI

struct BusMapExplorerView: View {
    let provider: BusProvider
    let initialBusInfo: BusInfo?

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

    init(provider: BusProvider, initialBusInfo: BusInfo? = nil) {
        self.provider = provider
        self.initialBusInfo = initialBusInfo
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            mapCard
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
        .task {
            await bootstrap()
        }
        .onDisappear {
            reloadTask?.cancel()
        }
    }

    private var mapCard: some View {
        ZStack(alignment: .topLeading) {
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
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let center = context.region.center
                mapCenter = center

                guard hasBootstrapped else { return }
                scheduleReload(around: center)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(mapSummary, systemImage: "mappin.and.ellipse")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                Text("Pan the map to refresh stops around the center point.")
                    .font(.transit(11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(AppTheme.warning)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(12)
        }
        .frame(height: 310)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.accentStrong.opacity(0.14), lineWidth: 1)
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
