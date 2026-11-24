import CoreLocation
import MapKit
import SwiftUI

private enum RoutePlanPointMode: String, CaseIterable, Identifiable {
    case origin = "From"
    case destination = "To"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .origin: "smallcircle.filled.circle"
        case .destination: "flag.fill"
        }
    }
}

/// Lightweight trip planner backed by MapKit rather than bundled timetable data.
///
/// Apple exposes a transit ETA but not a transit itinerary, so this shows how
/// long a trip takes by each mode and hands the turn-by-turn detail to the
/// Apple Maps app. Unlike the previous GTFS-backed planner it needs no local
/// database and works in every region.
struct RoutePlannerView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.themePalette) private var palette

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var sheetPresentation = MapSheetPresentation()
    @State private var selectedPointMode: RoutePlanPointMode = .origin
    @State private var editingPoint: RoutePlanPointMode?
    @State private var origin: RouteEndpoint?
    @State private var destination: RouteEndpoint?
    @State private var result: PlanLiteResult?
    @State private var selectedMode: PlanLiteMode = .transit
    @State private var isPlanning = false
    @State private var planTask: Task<Void, Never>?

    private var selectedLeg: PlanLiteLeg? {
        result?.leg(for: selectedMode)
    }

    private var drawableLeg: PlanLiteLeg? {
        guard let selectedLeg, selectedLeg.isDrawable else { return nil }
        return selectedLeg
    }

    var body: some View {
        MapSheetScaffold(
            title: "Trip planner",
            summary: isPlanning ? "Estimating…" : nil,
            isLoading: isPlanning,
            onRecenter: recenterOnUser,
            presentation: sheetPresentation,
            collapsedTitle: "Show trip planner"
        ) {
            mapView
        } headerContent: {
            Text(selectedPointMode == .origin
                 ? "Tap the map to place the starting pin."
                 : "Tap the map to place the destination pin.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } sheetContent: {
            plannerSections
        }
        .sheet(item: $editingPoint) { point in
            RouteEndpointPicker(field: point.rawValue, region: visibleRegion) { endpoint in
                setPoint(endpoint, for: point)
                frameSelectedPoints()
            }
        }
        .onAppear {
            if isPlanning { planIfReady() }
        }
        .onDisappear {
            planTask?.cancel()
        }
    }

    // MARK: - Map

    private var mapView: some View {
        MapReader { reader in
            Map(position: $cameraPosition) {
                UserAnnotation()

                if let drawableLeg {
                    MapPolyline(coordinates: drawableLeg.coordinates)
                        .stroke(
                            palette.accent,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }

                if let origin {
                    Marker("From", systemImage: RoutePlanPointMode.origin.symbol, coordinate: origin.coordinate)
                        .tint(palette.success)
                }

                if let destination {
                    Marker("To", systemImage: RoutePlanPointMode.destination.symbol, coordinate: destination.coordinate)
                        .tint(palette.danger)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard let coordinate = reader.convert(value.location, from: .local) else { return }
                        setPoint(.pin(at: coordinate, title: "Dropped Pin"), for: selectedPointMode)
                    }
            )
        }
    }

    // MARK: - Planner panel

    @ViewBuilder
    private var plannerSections: some View {
        VStack(spacing: 0) {
            endpointRow(.origin, endpoint: origin)
            Divider()
            endpointRow(.destination, endpoint: destination)
        }
        .padding(12)
        .background(palette.surfaceRaised.opacity(0.45), in: .rect(cornerRadius: 16))
        .padding(.top, 10)

        HStack(spacing: 10) {
            Picker("Map pin", selection: $selectedPointMode) {
                ForEach(RoutePlanPointMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Button("Clear trip", systemImage: "arrow.counterclockwise", action: resetPlan)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(origin == nil && destination == nil)
        }

        resultsContent
    }

    private func endpointRow(_ point: RoutePlanPointMode, endpoint: RouteEndpoint?) -> some View {
        Button {
            editingPoint = point
        } label: {
            HStack(spacing: 12) {
                Image(systemName: point.symbol)
                    .foregroundStyle(point == .origin ? palette.success : palette.danger)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(point.rawValue)
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                    Text(endpoint?.title ?? "Choose a location")
                        .font(.transitBody)
                        .foregroundStyle(endpoint == nil ? palette.textSecondary : palette.textPrimary)
                    if let subtitle = endpoint?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.transitCaption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(point == .origin ? "route.endpoint.from" : "route.endpoint.to")
    }

    @ViewBuilder
    private var resultsContent: some View {
        if let result {
            if result.legs.isEmpty {
                MapInfoBanner(
                    title: "No estimate available for these points.",
                    detail: nil,
                    icon: "clock"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Travel estimates", systemImage: "clock")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.accentText)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 4) {
                        ForEach(result.legs) { leg in
                            modeRow(leg)
                        }
                    }
                    .padding(4)
                    .background(palette.surfaceRaised.opacity(0.45), in: .rect(cornerRadius: 16))
                }
            }
        }

        if origin != nil && destination != nil {
            Button("Open in Apple Maps", systemImage: "arrow.up.forward.app") {
                openInMaps()
            }
            .buttonStyle(TransitPrimaryButtonStyle())

            Text("Apple Maps has the step-by-step route, including which services to catch.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func modeRow(_ leg: PlanLiteLeg) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))

        return Button {
            selectedMode = leg.mode
            frameRoute(leg)
        } label: {
            layout {
                HStack(spacing: 12) {
                    Image(systemName: leg.mode.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(leg.mode == selectedMode ? palette.accentText : palette.textSecondary)
                        .frame(width: 26)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.mode.title)
                            .font(.transitBody)
                            .foregroundStyle(palette.textPrimary)
                        Text(distanceText(leg.distanceMeters))
                            .font(.transitCaption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(durationText(leg.travelTime))
                    .font(.transitBody)
                    .monospacedDigit()
                    .foregroundStyle(leg.mode == selectedMode ? palette.accentText : palette.textPrimary)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                (leg.mode == selectedMode ? palette.accent.opacity(0.10) : Color.clear),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(leg.mode == selectedMode ? .isSelected : [])
    }

    // MARK: - Actions

    private func setPoint(_ endpoint: RouteEndpoint, for point: RoutePlanPointMode) {
        switch point {
        case .origin:
            origin = endpoint
            if destination == nil { selectedPointMode = .destination }
        case .destination:
            destination = endpoint
            if origin == nil { selectedPointMode = .origin }
        }
        planIfReady()
    }

    private func resetPlan() {
        planTask?.cancel()
        origin = nil
        destination = nil
        result = nil
        isPlanning = false
        selectedPointMode = .origin
    }

    private func planIfReady() {
        guard let origin, let destination else { return }
        planTask?.cancel()
        result = nil
        isPlanning = true

        planTask = Task {
            let planned = await PlanLiteService.shared.plan(
                from: origin.coordinate,
                to: destination.coordinate
            )
            guard !Task.isCancelled else { return }
            result = planned
            isPlanning = false

            // Fall back to a mode Apple could actually answer for.
            if planned.leg(for: selectedMode) == nil, let first = planned.legs.first {
                selectedMode = first.mode
            }
            if let leg = planned.leg(for: selectedMode) {
                frameRoute(leg)
            } else {
                frameSelectedPoints()
            }
        }
    }

    private func openInMaps() {
        guard let origin, let destination else { return }
        PlanLiteService.shared.openInAppleMaps(
            from: origin.mapItem,
            to: destination.mapItem,
            mode: selectedMode
        )
    }

    // MARK: - Camera

    private func recenterOnUser() {
        Task {
            if let location = try? await LocationManager().currentLocation() {
                cameraPosition = .region(region(containing: [location.coordinate]))
            } else {
                cameraPosition = .userLocation(fallback: .automatic)
            }
        }
    }

    private func frameRoute(_ leg: PlanLiteLeg) {
        let coordinates = leg.isDrawable
            ? leg.coordinates
            : [origin?.coordinate, destination?.coordinate].compactMap { $0 }
        guard !coordinates.isEmpty else { return }
        cameraPosition = .region(region(containing: coordinates))
    }

    private func frameSelectedPoints() {
        let coordinates = [origin?.coordinate, destination?.coordinate].compactMap { $0 }
        guard !coordinates.isEmpty else { return }
        cameraPosition = .region(region(containing: coordinates))
    }

    private func region(containing coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else {
            return MKCoordinateRegion(
                center: coordinates[0],
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.01)
            )
        )
    }

    // MARK: - Formatting

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func distanceText(_ meters: CLLocationDistance) -> String {
        meters < 1000
            ? "\(Int(meters.rounded())) m"
            : String(format: "%.1f km", meters / 1000)
    }
}
