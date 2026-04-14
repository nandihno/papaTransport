//
//  BusStopSettingsViews.swift
//  myLatest
//
//  Settings views for searching and managing favourite bus stops.
//  Uses an Apple Maps view with pins for bus stop selection.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Favourite Bus Stops List

struct FavouriteBusStopsView: View {
    @EnvironmentObject private var store: FavouriteBusStopStore

    let provider: BusProvider

    init(provider: BusProvider = .queenslandTransLink) {
        self.provider = provider
    }

    var body: some View {
        List {
            if store.favourites(for: provider).isEmpty {
                ContentUnavailableView {
                    Label("No Favourite Stops", systemImage: "star.slash")
                } description: {
                    Text("Tap the + button to browse the map and add bus stops.")
                }
            } else {
                ForEach(store.favourites(for: provider)) { stop in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.stopName)
                            .font(.body)
                        if let code = stop.stopCode {
                            Text("Stop #\(code)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    store.delete(offsets: offsets, provider: provider)
                }
            }
        }
        .navigationTitle("Favourite Stops")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BusStopMapView(provider: provider)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

// MARK: - Map-based Bus Stop Picker

/// A bus stop annotation for the map.
struct BusStopAnnotation: Identifiable, Hashable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let coordinate: CLLocationCoordinate2D

    var id: String { stopId }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stopId)
    }

    static func == (lhs: BusStopAnnotation, rhs: BusStopAnnotation) -> Bool {
        lhs.stopId == rhs.stopId
    }
}

struct BusStopMapView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FavouriteBusStopStore

    let provider: BusProvider

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleStops: [BusStopAnnotation] = []
    @State private var selectedStop: BusStopAnnotation?
    @State private var mapSpan: Double = 0.01 // track current zoom level
    @State private var loadTask: Task<Void, Never>?
    @State private var showStopDetail = false
    @State private var locationManager = CLLocationManager()

    // Only show pins when zoomed in enough (roughly < 3km span)
    private var shouldShowPins: Bool {
        mapSpan < 0.03
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition, selection: $selectedStop) {
                UserAnnotation()

                if shouldShowPins {
                    ForEach(visibleStops) { stop in
                        Marker(
                            stop.stopName,
                            systemImage: store.contains(stopId: stop.stopId, provider: provider) ? "star.fill" : "bus.fill",
                            coordinate: stop.coordinate
                        )
                        .tint(store.contains(stopId: stop.stopId, provider: provider) ? .yellow : .blue)
                        .tag(stop)
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let span = context.region.span
                mapSpan = max(span.latitudeDelta, span.longitudeDelta)

                if shouldShowPins {
                    loadStopsForRegion(context.region)
                } else {
                    visibleStops = []
                }
            }
            .onChange(of: selectedStop) { _, newValue in
                if newValue != nil {
                    showStopDetail = true
                }
            }

            if !shouldShowPins {
                ZoomInBanner()
            }
        }
        .navigationTitle("Find Bus Stops")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            locationManager.requestWhenInUseAuthorization()
        }
        .sheet(isPresented: $showStopDetail) {
            selectedStop = nil
        } content: {
            if let stop = selectedStop {
                BusStopDetailSheet(stop: stop, provider: provider, store: store) {
                    showStopDetail = false
                }
                .presentationDetents([.fraction(0.25)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func loadStopsForRegion(_ region: MKCoordinateRegion) {
        loadTask?.cancel()
        loadTask = Task {
            let minLat = region.center.latitude - region.span.latitudeDelta / 2
            let maxLat = region.center.latitude + region.span.latitudeDelta / 2
            let minLon = region.center.longitude - region.span.longitudeDelta / 2
            let maxLon = region.center.longitude + region.span.longitudeDelta / 2

            do {
                let stops: [GTFSStop]
                switch provider {
                case .queenslandTransLink:
                    stops = try await GTFSDatabase.shared.stopsInRegion(
                        minLat: minLat, maxLat: maxLat,
                        minLon: minLon, maxLon: maxLon,
                        limit: 150
                    )
                case .victorianPTV:
                    stops = try await VictorianBusGTFSDatabase.shared.stopsInRegion(
                        minLat: minLat, maxLat: maxLat,
                        minLon: minLon, maxLon: maxLon,
                        limit: 150
                    )
                }
                guard !Task.isCancelled else { return }
                visibleStops = stops.map { stop in
                    BusStopAnnotation(
                        stopId: stop.stopId,
                        stopName: stop.stopName,
                        stopCode: stop.stopCode,
                        coordinate: CLLocationCoordinate2D(latitude: stop.stopLat, longitude: stop.stopLon)
                    )
                }
            } catch {
                // DB not ready — ignore
            }
        }
    }
}

// MARK: - Zoom In Banner

private struct ZoomInBanner: View {
    var body: some View {
        Text("Zoom in to see bus stops")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
    }
}

// MARK: - Stop Detail Sheet

private struct BusStopDetailSheet: View {
    let stop: BusStopAnnotation
    let provider: BusProvider
    let store: FavouriteBusStopStore
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(stop.stopName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let code = stop.stopCode {
                    Text("Stop #\(code)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if store.contains(stopId: stop.stopId, provider: provider) {
                Button(role: .destructive) {
                    store.remove(stopId: stop.stopId, provider: provider)
                    onDismiss()
                } label: {
                    Label("Remove from Favourites", systemImage: "star.slash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    store.add(FavouriteBusStop(
                        provider: provider,
                        stopId: stop.stopId,
                        stopName: stop.stopName,
                        stopCode: stop.stopCode,
                        latitude: stop.coordinate.latitude,
                        longitude: stop.coordinate.longitude
                    ))
                    onDismiss()
                } label: {
                    Label("Add to Favourites", systemImage: "star.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

// MARK: - Search result model (used by GTFSDatabase)

struct BusStopSearchResult: Identifiable {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double

    var id: String { stopId }
}
