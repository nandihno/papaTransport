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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
            if #available(iOS 27.1, *),
               horizontalSizeClass == .regular || !proxy.reservedRegions(kind: .division).isEmpty {
                ArrangementView {
                    mapView
                } secondary: {
                    plannerPanel
                        .splitArrangementLayoutRatio(idealHorizontal: 0.44, idealVertical: 0.42)
                }
                .arrangementViewStyle(.split)
            } else {
                compactLayout(in: proxy.size)
            }
        }
        .onDisappear {
            planTask?.cancel()
        }
    }

    private func compactLayout(in size: CGSize) -> some View {
        let sideBySide = size.width >= 520 && size.width > size.height
        let layout = sideBySide
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))

        return layout {
            mapView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            plannerPanel
                .frame(
                    width: sideBySide ? min(size.width * 0.44, 420) : nil,
                    height: sideBySide ? nil : size.height * 0.43
                )
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

    // MARK: - Planner panel

    private var plannerPanel: some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerLayout {
                    Label("Trip endpoints", systemImage: "map.fill")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.accentText)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button("Use current location", systemImage: "location.fill") {
                            useCurrentLocationAsOrigin()
                        }
                        .labelStyle(.iconOnly)

                        Button("Clear trip", systemImage: "arrow.counterclockwise") {
                            resetPlan()
                        }
                        .labelStyle(.iconOnly)
                        .disabled(originCoordinate == nil && destinationCoordinate == nil && errorMessage == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Picker("Point", selection: $selectedPointMode) {
                    ForEach(RoutePlanPointMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(instructionText)
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)

                statusContent
                resultsContent
            }
            .padding(16)
            .frame(maxWidth: 500, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.screenBackground)
    }

    private var instructionText: String {
        switch selectedPointMode {
        case .origin:
            originCoordinate == nil ? "Tap the map to choose a starting point." : "Tap the map to move the starting point."
        case .destination:
            destinationCoordinate == nil ? "Tap the map to choose a destination." : "Tap the map to move the destination."
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if let result, !result.legs.isEmpty {
            CardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Travel estimates")
                        .font(.transitBody)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(result.legs) { leg in
                        modeRow(leg)
                    }
                }
            }

            Button("Open in Apple Maps", systemImage: "arrow.up.forward.app") {
                openInMaps()
            }
            .buttonStyle(TransitPrimaryButtonStyle())

            Text("Apple Maps has the step-by-step route, including which services to catch.")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
        }
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
        } else if result?.legs.isEmpty ?? false {
            Text("No estimate available for these points.")
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

    private func setSelectedPoint(_ coordinate: CLLocationCoordinate2D) {
        switch selectedPointMode {
        case .origin:
            originCoordinate = coordinate
            if destinationCoordinate == nil { selectedPointMode = .destination }
        case .destination:
            destinationCoordinate = coordinate
            if originCoordinate == nil { selectedPointMode = .origin }
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
