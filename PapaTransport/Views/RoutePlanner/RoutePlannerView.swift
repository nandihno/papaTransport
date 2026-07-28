import CoreLocation
import MapKit
import SwiftUI

private enum RoutePlanPointMode: String, CaseIterable {
    case origin = "From"
    case destination = "To"
}

/// Lightweight trip planner backed by MapKit rather than bundled timetable data.
///
/// Apple exposes a transit ETA but not a transit itinerary, so this shows how
/// long a trip takes by each mode and hands the turn-by-turn detail to the
/// Apple Maps app. Unlike the previous GTFS-backed planner it needs no local
/// database and works in every region.
struct RoutePlannerView: View {
    @Environment(\.themePalette) private var palette

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedPointMode: RoutePlanPointMode = .origin
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var result: PlanLiteResult?
    @State private var selectedMode: PlanLiteMode = .transit
    @State private var isPlanning = false
    @State private var errorMessage: String?
    @State private var planTask: Task<Void, Never>?

    private var selectedLeg: PlanLiteLeg? {
        result?.leg(for: selectedMode)
    }

    private var drawableLeg: PlanLiteLeg? {
        guard let selectedLeg, selectedLeg.isDrawable else { return nil }
        return selectedLeg
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                mapView
                    .ignoresSafeArea()

                headerOverlay(topInset: proxy.safeAreaInsets.top)

                VStack {
                    Spacer()
                    resultSheet(safeBottom: proxy.safeAreaInsets.bottom)
                }
            }
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

                if let originCoordinate {
                    Marker("From", systemImage: "smallcircle.filled.circle", coordinate: originCoordinate)
                        .tint(palette.success)
                }

                if let destinationCoordinate {
                    Marker("To", systemImage: "flag.fill", coordinate: destinationCoordinate)
                        .tint(palette.danger)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard let coordinate = reader.convert(value.location, from: .local) else { return }
                        setSelectedPoint(coordinate)
                    }
            )
        }
    }

    // MARK: - Header

    private func headerOverlay(topInset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Point", selection: $selectedPointMode) {
                    ForEach(RoutePlanPointMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)

                Text(instructionText)
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            VStack(spacing: 10) {
                overlayControlButton(systemName: "location.fill") {
                    useCurrentLocationAsOrigin()
                }
                overlayControlButton(systemName: "arrow.counterclockwise") {
                    resetPlan()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 8)
    }

    private var instructionText: String {
        if originCoordinate == nil { return "Tap the map to set your starting point" }
        if destinationCoordinate == nil { return "Now tap your destination" }
        return "Tap the map to move the \(selectedPointMode.rawValue.lowercased()) point"
    }

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

    // MARK: - Result sheet

    private func resultSheet(safeBottom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Plan Trip", systemImage: "map.fill")
                .font(.transitHeadline)
                .foregroundStyle(palette.accentText)

            statusContent

            if let result, !result.legs.isEmpty {
                ForEach(result.legs) { leg in
                    modeRow(leg)
                }

                Button {
                    openInMaps()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("Open in Apple Maps")
                            .font(.transitBody)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(palette.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(palette.accentText)
                }
                .buttonStyle(.plain)

                Text("Apple Maps has the step-by-step route, including which services to catch.")
                    .font(.transitCaption)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceRaised.opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(0.14), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, safeBottom + 8)
    }

    @ViewBuilder
    private var statusContent: some View {
        if isPlanning {
            HStack(spacing: 8) {
                ProgressView()
                Text("Estimating…")
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
            }
        } else if let errorMessage {
            Text(errorMessage)
                .font(.transitCaption)
                .foregroundStyle(palette.warning)
        } else if originCoordinate == nil || destinationCoordinate == nil {
            Text("Choose a start and destination to see how long the trip takes.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
        } else if result?.legs.isEmpty ?? false {
            Text("No estimate available for these points.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func modeRow(_ leg: PlanLiteLeg) -> some View {
        Button {
            selectedMode = leg.mode
            frameRoute(leg)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: leg.mode.symbolName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(leg.mode == selectedMode ? palette.accentText : palette.textSecondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(leg.mode.title)
                        .font(.transitBody)
                        .foregroundStyle(palette.textPrimary)
                    Text(distanceText(leg.distanceMeters))
                        .font(.transitCaption)
                        .foregroundStyle(palette.textTertiary)
                }

                Spacer()

                Text(durationText(leg.travelTime))
                    .font(.transitBody)
                    .foregroundStyle(leg.mode == selectedMode ? palette.accentText : palette.textPrimary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                (leg.mode == selectedMode ? palette.accent.opacity(0.10) : Color.clear),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func setSelectedPoint(_ coordinate: CLLocationCoordinate2D) {
        switch selectedPointMode {
        case .origin:
            originCoordinate = coordinate
            if destinationCoordinate == nil { selectedPointMode = .destination }
        case .destination:
            destinationCoordinate = coordinate
        }
        planIfReady()
    }

    private func useCurrentLocationAsOrigin() {
        Task {
            guard let location = try? await LocationManager().currentLocation() else {
                errorMessage = "Could not get your current location."
                return
            }
            originCoordinate = location.coordinate
            if destinationCoordinate == nil { selectedPointMode = .destination }
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
            )
            planIfReady()
        }
    }

    private func resetPlan() {
        planTask?.cancel()
        originCoordinate = nil
        destinationCoordinate = nil
        result = nil
        errorMessage = nil
        isPlanning = false
        selectedPointMode = .origin
    }

    private func planIfReady() {
        guard let originCoordinate, let destinationCoordinate else { return }
        planTask?.cancel()
        errorMessage = nil
        isPlanning = true

        planTask = Task {
            let planned = await PlanLiteService.shared.plan(
                from: originCoordinate,
                to: destinationCoordinate
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
        guard let originCoordinate, let destinationCoordinate else { return }
        PlanLiteService.shared.openInAppleMaps(
            from: originCoordinate,
            to: destinationCoordinate,
            mode: selectedMode
        )
    }

    // MARK: - Camera

    private func frameRoute(_ leg: PlanLiteLeg) {
        let coordinates = leg.isDrawable
            ? leg.coordinates
            : [originCoordinate, destinationCoordinate].compactMap { $0 }
        guard !coordinates.isEmpty else { return }
        cameraPosition = .region(region(containing: coordinates))
    }

    private func frameSelectedPoints() {
        let coordinates = [originCoordinate, destinationCoordinate].compactMap { $0 }
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
