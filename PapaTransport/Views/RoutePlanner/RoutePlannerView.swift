import CoreLocation
import MapKit
import SwiftUI

private enum RoutePlanPointMode: String, CaseIterable {
    case origin = "From"
    case destination = "To"
}

struct RoutePlannerView: View {
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue
    @Environment(\.themePalette) private var palette

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedPointMode: RoutePlanPointMode = .origin
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var result: RoutePlanResult?
    @State private var selectedOptionId: String?
    @State private var isPlanning = false
    @State private var errorMessage: String?
    @State private var planTask: Task<Void, Never>?
    @State private var sheetOffset: CGFloat = 0
    @State private var isCollapsed = false

    private var transportRegion: TransportRegion {
        TransportRegion(rawValue: transportRegionRaw) ?? .victorian
    }

    private var selectedOption: RoutePlanOption? {
        guard let selectedOptionId else { return result?.options.first }
        return result?.options.first { $0.id == selectedOptionId } ?? result?.options.first
    }

    var body: some View {
        Group {
            if transportRegion == .victorian {
                plannerBody
            } else {
                unsupportedView
            }
        }
        .onDisappear {
            planTask?.cancel()
        }
    }

    private var plannerBody: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                mapView
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.42),
                        Color.black.opacity(0.12),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

                headerOverlay(topInset: proxy.safeAreaInsets.top)
                routeLegendOverlay(topInset: proxy.safeAreaInsets.top)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    resultSheet(safeBottom: max(proxy.safeAreaInsets.bottom, 12))
                }
            }
        }
        .background(palette.backgroundBase)
    }

    private var mapView: some View {
        MapReader { reader in
            Map(position: $cameraPosition) {
                UserAnnotation()

                if let selectedOption {
                    let firstTransitLegId = selectedOption.legs.first { $0.routeShortName != "Walk" }?.id
                    ForEach(selectedOption.legs) { leg in
                        if leg.polylineCoordinates.count > 1 {
                            if leg.routeShortName == "Walk" {
                                MapPolyline(coordinates: leg.polylineCoordinates)
                                    .stroke(
                                        Color.gray.opacity(0.85),
                                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 4])
                                    )
                            } else {
                                MapPolyline(coordinates: leg.polylineCoordinates)
                                    .stroke(
                                        leg.id == firstTransitLegId ? palette.accent : AppTheme.info,
                                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                                    )
                            }
                        }
                    }
                }

                if let originCoordinate {
                    Marker("From", systemImage: "smallcircle.filled.circle", coordinate: originCoordinate)
                        .tint(AppTheme.success)
                }

                if let destinationCoordinate {
                    Marker("To", systemImage: "flag.fill", coordinate: destinationCoordinate)
                        .tint(AppTheme.danger)
                }

                if let origin = result?.selectedOrigin {
                    Marker("Board", systemImage: "bus.fill", coordinate: origin.coordinate)
                        .tint(palette.accent)
                }

                if let destination = result?.selectedDestination {
                    Marker("Alight", systemImage: "figure.walk.arrival", coordinate: destination.coordinate)
                        .tint(palette.accentStrong)
                }

                if let selectedOption {
                    ForEach(selectedOption.legs.dropFirst().filter { $0.routeShortName != "Walk" }) { leg in
                        Marker("Transfer", systemImage: "arrow.triangle.swap", coordinate: leg.originStop.coordinate)
                            .tint(AppTheme.info)
                    }
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

    @ViewBuilder
    private func headerOverlay(topInset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .foregroundStyle(palette.accent)
                    Text("Plan Trip")
                        .font(.transit(14, weight: .bold))
                }

                Picker("Point", selection: $selectedPointMode) {
                    ForEach(RoutePlanPointMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Text(instructionText)
                    .font(.transit(11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }

            Spacer()

            VStack(spacing: 12) {
                overlayControlButton(systemName: "location.fill", action: useCurrentLocationAsOrigin)
                overlayControlButton(systemName: "arrow.counterclockwise", action: resetPlan)
            }
        }
        .padding(.top, max(topInset, 12))
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func routeLegendOverlay(topInset: CGFloat) -> some View {
        if let selectedOption, selectedOption.legs.contains(where: { $0.polylineCoordinates.count > 1 }) {
            HStack {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    legendLine(label: "Main bus", color: palette.accent, isDashed: false)

                    if selectedOption.transferCount > 0 {
                        legendLine(label: "Transfer bus", color: AppTheme.info, isDashed: false)
                    }

                    if selectedOption.legs.contains(where: { $0.routeShortName == "Walk" }) {
                        legendLine(label: "Walk", color: Color.gray.opacity(0.85), isDashed: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
            }
            .padding(.top, max(topInset, 12) + 124)
            .padding(.horizontal, 18)
            .allowsHitTesting(false)
        }
    }

    private func legendLine(label: String, color: Color, isDashed: Bool) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: isDashed ? [6, 4] : [])
                )
                .frame(width: 28, height: 8)

            Text(label)
                .font(.transit(11, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
    }

    private var instructionText: String {
        switch (originCoordinate, destinationCoordinate) {
        case (nil, _):
            return "Tap the map to set your starting point."
        case (_, nil):
            return "Tap the map to set your destination."
        default:
            return "Tap again to adjust the selected point."
        }
    }

    private var sheetDragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let dragY = value.translation.height
                let baseOffset = isCollapsed ? 290.0 : 0.0
                let newOffset = baseOffset + dragY
                
                if newOffset < 0 {
                    sheetOffset = newOffset * 0.2
                } else {
                    sheetOffset = newOffset
                }
            }
            .onEnded { value in
                let dragY = value.translation.height
                let velocityY = value.predictedEndLocation.y - value.location.y
                
                if abs(dragY) < 5 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isCollapsed.toggle()
                        sheetOffset = isCollapsed ? 290 : 0
                    }
                    return
                }
                
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    if isCollapsed {
                        if dragY < -60 || velocityY < -150 {
                            isCollapsed = false
                            sheetOffset = 0
                        } else {
                            sheetOffset = 290
                        }
                    } else {
                        if dragY > 60 || velocityY > 150 {
                            isCollapsed = true
                            sheetOffset = 290
                        } else {
                            sheetOffset = 0
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var collapsedHeaderContent: some View {
        if isPlanning {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(palette.accent)
                Text("Finding bus trips...")
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if let errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.danger)
                Text("Trip planning unavailable")
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if originCoordinate == nil || destinationCoordinate == nil {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(palette.accent)
                Text("Tap map to plan route")
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if let result, result.options.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "bus.doubledecker")
                    .font(.subheadline)
                    .foregroundStyle(palette.accent)
                Text("No bus trip found")
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if let option = selectedOption {
            HStack(spacing: 8) {
                Text(option.routeSummary)
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                
                Spacer()
                
                Text("\(option.durationMinutes) min")
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.accent)
                
                Text("•")
                    .font(.transit(12, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
                
                Text("\(option.departureTime) - \(option.arrivalTime)")
                    .font(.transit(12, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func resultSheet(safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(palette.textTertiary.opacity(0.5))
                    .frame(width: 40, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, isCollapsed ? 8 : 12)
                
                if isCollapsed {
                    collapsedHeaderContent
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.clear)
            .contentShape(Rectangle())
            .gesture(sheetDragGesture)
            
            if !isCollapsed {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        statusContent

                        if let result {
                            snappedStopsCard(result)
                            optionsContent(result)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, safeBottom + 10)
                }
                .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(palette.surfaceOverlay.opacity(0.58))
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
        .offset(y: sheetOffset)
    }

    @ViewBuilder
    private var statusContent: some View {
        if isPlanning {
            infoBanner(
                title: "Finding bus trips",
                detail: "Checking direct trips and options with up to three transfers.",
                icon: "arrow.triangle.2.circlepath"
            )
        } else if let errorMessage {
            infoBanner(title: "Trip planning unavailable", detail: errorMessage, icon: "exclamationmark.triangle.fill")
        } else if originCoordinate == nil || destinationCoordinate == nil {
            infoBanner(
                title: "Choose two points",
                detail: "Tap the map to set a from point and a destination.",
                icon: "mappin.and.ellipse"
            )
        } else if let result, result.options.isEmpty {
            infoBanner(
                title: "No bus trip found",
                detail: "The nearest stops do not have an upcoming direct trip or same-stop transfer option within three transfers.",
                icon: "bus.doubledecker"
            )
        }
    }

    private func snappedStopsCard(_ result: RoutePlanResult) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nearest Stops")
                    .font(.transit(15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                if let origin = result.selectedOrigin {
                    snappedStopRow(label: "From", stop: origin, color: AppTheme.success)
                }
                if let destination = result.selectedDestination {
                    snappedStopRow(label: "To", stop: destination, color: AppTheme.danger)
                }
            }
        }
    }

    @ViewBuilder
    private func optionsContent(_ result: RoutePlanResult) -> some View {
        if !result.options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trip Options")
                    .font(.transit(15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                ForEach(result.options) { option in
                    optionRow(option)
                }
            }
        }
    }

    private func optionRow(_ option: RoutePlanOption) -> some View {
        Button {
            selectedOptionId = option.id
            frameRoute(option)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(option.routeSummary)
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.transferCount == 0 ? option.displayHeadsign : transferCountText(option.transferCount))
                            .font(.transit(14, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(2)
                        Text(option.transferSummary ?? option.routeLongName)
                            .font(.transit(11, weight: .medium))
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(2)
                    }

                    Spacer()
                }

                HStack(spacing: 12) {
                    timeBadge(title: "Leave", value: option.departureTime)
                    Image(systemName: "arrow.right")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textSecondary)
                    timeBadge(title: "Arrive", value: option.arrivalTime)
                    Spacer()
                    Text("\(option.durationMinutes) min")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.accent)
                }

                ForEach(option.legs) { leg in
                    legRow(leg)
                }
            }
            .padding(14)
            .background(
                selectedOptionId == option.id || (selectedOptionId == nil && result?.options.first?.id == option.id)
                    ? palette.surfaceRaised.opacity(0.92)
                    : palette.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.textTertiary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func snappedStopRow(label: String, stop: RoutePlanStopCandidate, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.transit(11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44)
                .padding(.vertical, 5)
                .background(color, in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.stopName)
                    .font(.transit(13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text("\(Int(stop.distanceMeters.rounded())) m from selected point")
                    .font(.transit(11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()
        }
    }

    private func transferCountText(_ count: Int) -> String {
        count == 1 ? "1 transfer" : "\(count) transfers"
    }

    private func legRow(_ leg: RoutePlanLeg) -> some View {
        let isWalk = leg.routeShortName == "Walk"
        return HStack(alignment: .top, spacing: 10) {
            Text(isWalk ? "Walk" : leg.routeShortName)
                .font(.transit(12, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 44)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isWalk ? Color.gray.opacity(0.68) : palette.accent.opacity(0.86), in: Capsule())

            VStack(alignment: .leading, spacing: 3) {
                if isWalk {
                    Text("Walk \(Int(leg.destinationStop.distanceMeters)) m (\(leg.durationMinutes) min)")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text("To \(leg.destinationStop.stopName)")
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("\(leg.departureTime) \(leg.originStop.stopName)")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text("\(leg.arrivalTime) \(leg.destinationStop.stopName)")
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    private func timeBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.transit(10, weight: .bold))
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .font(.transit(13, weight: .bold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    private func infoBanner(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text(detail)
                    .font(.transit(12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(palette.surfaceRaised.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(0.14), lineWidth: 1)
        }
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

    private var unsupportedView: some View {
        ScrollView {
            VStack(spacing: 16) {
                CardContainer {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Plan Trip", systemImage: "map.fill")
                            .font(.transit(18, weight: .bold))
                            .foregroundStyle(palette.accent)
                        Text("Bus trip planning is currently available for Victorian Transport only.")
                            .font(.transit(14, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                    }
                }
            }
            .padding()
        }
        .background(palette.screenBackground)
    }

    private func setSelectedPoint(_ coordinate: CLLocationCoordinate2D) {
        switch selectedPointMode {
        case .origin:
            originCoordinate = coordinate
            selectedPointMode = .destination
        case .destination:
            destinationCoordinate = coordinate
        }

        result = nil
        selectedOptionId = nil
        errorMessage = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isCollapsed = false
            sheetOffset = 0
        }
        planIfReady()
    }

    private func useCurrentLocationAsOrigin() {
        Task {
            do {
                let location = try await LocationManager().currentLocation()
                originCoordinate = location.coordinate
                selectedPointMode = .destination
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                    )
                )
                result = nil
                selectedOptionId = nil
                errorMessage = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isCollapsed = false
                    sheetOffset = 0
                }
                planIfReady()
            } catch {
                errorMessage = error.localizedDescription
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isCollapsed = false
                    sheetOffset = 0
                }
            }
        }
    }

    private func resetPlan() {
        planTask?.cancel()
        originCoordinate = nil
        destinationCoordinate = nil
        result = nil
        selectedOptionId = nil
        errorMessage = nil
        selectedPointMode = .origin
        isPlanning = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isCollapsed = false
            sheetOffset = 0
        }
    }

    private func planIfReady() {
        guard let originCoordinate, let destinationCoordinate else { return }
        planTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isCollapsed = false
            sheetOffset = 0
        }
        planTask = Task {
            isPlanning = true
            errorMessage = nil
            do {
                let planned = try await VictorianBusRoutePlannerService.shared.planTrips(
                    from: originCoordinate,
                    to: destinationCoordinate
                )
                guard !Task.isCancelled else { return }
                result = planned
                selectedOptionId = planned.options.first?.id
                if let option = planned.options.first {
                    frameRoute(option)
                } else {
                    frameSelectedPoints()
                }
            } catch {
                guard !Task.isCancelled else { return }
                result = nil
                selectedOptionId = nil
                errorMessage = error.localizedDescription
                frameSelectedPoints()
            }
            isPlanning = false
        }
    }

    private func frameRoute(_ option: RoutePlanOption) {
        let coordinates = option.polylineCoordinates
        guard !coordinates.isEmpty else {
            frameSelectedPoints()
            return
        }

        cameraPosition = .region(region(containing: coordinates))
    }

    private func frameSelectedPoints() {
        let coordinates = [originCoordinate, destinationCoordinate].compactMap { $0 }
        guard !coordinates.isEmpty else { return }
        cameraPosition = .region(region(containing: coordinates))
    }

    private func region(containing coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let minLat = coordinates.map(\.latitude).min() ?? -37.8136
        let maxLat = coordinates.map(\.latitude).max() ?? -37.8136
        let minLon = coordinates.map(\.longitude).min() ?? 144.9631
        let maxLon = coordinates.map(\.longitude).max() ?? 144.9631
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLat - minLat) * 1.45),
            longitudeDelta: max(0.01, (maxLon - minLon) * 1.45)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
