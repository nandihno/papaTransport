//
//  BusCard.swift
//  myLatest
//

import SwiftUI
import MapKit

// MARK: - Bus Card

struct BusCard: View {
    let title: String
    let busInfo: BusInfo
    let showsNearby: Bool
    let showsFavourites: Bool

    private let selectedStopIDBinding: Binding<String?>?

    @Environment(\.themePalette) private var palette
    @State private var selectedTripRequest: BusTripRequest?
    @State private var localSelectedStopID: String?
    @State private var expandedStopIDs: Set<String> = []

    init(
        title: String = "Bus Departures",
        busInfo: BusInfo,
        selectedStopID: Binding<String?>? = nil,
        showsNearby: Bool = true,
        showsFavourites: Bool = true
    ) {
        self.title = title
        self.busInfo = busInfo
        self.selectedStopIDBinding = selectedStopID
        self.showsNearby = showsNearby
        self.showsFavourites = showsFavourites
    }

    private var selectedStopID: String? {
        selectedStopIDBinding?.wrappedValue ?? localSelectedStopID
    }

    private var allDisplayedStopIDs: [String] {
        displayedNearbyStops.map(\.id) + displayedFavouriteStops.map(\.id)
    }

    private var displayedNearbyStops: [NearbyBusStop] {
        showsNearby ? busInfo.nearbyStops : []
    }

    private var displayedFavouriteStops: [NearbyBusStop] {
        showsFavourites ? busInfo.favouriteStops : []
    }

    private var isExternallyControlled: Bool {
        selectedStopIDBinding != nil
    }

    private var vehicleIconName: String {
        busInfo.provider == .victorianTrainPTV ? "tram.fill" : "bus.fill"
    }

    private var nearbySubjectNoun: String {
        busInfo.provider == .victorianTrainPTV ? "train stations" : "bus stops"
    }

    private var nearbySearchRadiusDescription: String {
        busInfo.provider == .victorianTrainPTV ? "5km" : "300m"
    }

    private var emptyStateMessage: String {
        if showsFavourites {
            return busInfo.provider == .victorianTrainPTV
                ? "No saved favourite train stations currently have departures."
                : "No saved favourite bus stops currently have departures."
        }

        return "No \(nearbySubjectNoun) found within \(nearbySearchRadiusDescription) of the map center. Pan the map to search elsewhere."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: vehicleIconName)
                    .font(.transit(18, weight: .bold))
                    .foregroundStyle(palette.accentStrong)
                Spacer()
                Text(busInfo.localTimeAtFetch)
                    .font(.transit(11, weight: .bold))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            if busInfo.locationAvailable {
                Label("Tap a departure to see where that trip continues.", systemImage: "list.bullet.rectangle.portrait")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            if !busInfo.locationAvailable {
                Label("Location unavailable. Enable Location Services to see nearby \(nearbySubjectNoun).",
                      systemImage: "location.slash.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.warning)
            } else if displayedNearbyStops.isEmpty && displayedFavouriteStops.isEmpty {
                Label(
                    emptyStateMessage,
                    systemImage: "mappin.slash"
                )
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
            } else {
                ForEach(busInfo.alerts) { alert in
                    BusAlertRow(alert: alert)
                }

                if !displayedNearbyStops.isEmpty {
                    Label("Nearby", systemImage: "location.fill")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textSecondary)
                        .padding(.top, 4)
                    ForEach(displayedNearbyStops) { stop in
                        BusStopSection(
                            stop: stop,
                            isTripDetailEnabled: true,
                            isSelected: selectedStopID == stop.id,
                            isExpanded: expandedStopIDs.contains(stop.id),
                            onToggleExpanded: {
                                toggleExpansion(for: stop.id)
                            },
                            onSelectStop: {
                                setSelectedStopID(stop.id)
                            }
                        ) { departure in
                            selectedTripRequest = BusTripRequest(
                                provider: busInfo.provider,
                                stopId: stop.id,
                                departure: departure
                            )
                        }
                    }
                }

                if !displayedFavouriteStops.isEmpty {
                    if !displayedNearbyStops.isEmpty {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.vertical, 4)
                    }
                    Label("Favourites", systemImage: "star.fill")
                        .font(.caption.bold())
                        .foregroundStyle(palette.accentStrong)
                    ForEach(displayedFavouriteStops) { stop in
                        BusStopSection(
                            stop: stop,
                            isTripDetailEnabled: true,
                            isSelected: selectedStopID == stop.id,
                            isExpanded: expandedStopIDs.contains(stop.id),
                            onToggleExpanded: {
                                toggleExpansion(for: stop.id)
                            },
                            onSelectStop: {
                                setSelectedStopID(stop.id)
                            }
                        ) { departure in
                            selectedTripRequest = BusTripRequest(
                                provider: busInfo.provider,
                                stopId: stop.id,
                                departure: departure
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(palette.surfaceRaised.opacity(0.10))

                // Thin accent gradient bar along top edge
                LinearGradient(
                    colors: [palette.accentStrong.opacity(0.40), palette.accent.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 24,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 24,
                        style: .continuous
                    )
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.accentStrong.opacity(0.14), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear {
            synchronizeSelectionWithCurrentStops()
        }
        .onChange(of: selectedStopID) { _, newValue in
            guard let newValue else { return }
            expandedStopIDs.insert(newValue)
        }
        .onChange(of: allDisplayedStopIDs) { _, _ in
            synchronizeSelectionWithCurrentStops()
        }
        .sheet(item: $selectedTripRequest) { request in
            BusTripDetailSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func setSelectedStopID(_ stopID: String?) {
        if let selectedStopIDBinding {
            selectedStopIDBinding.wrappedValue = stopID
        } else {
            localSelectedStopID = stopID
        }
    }

    private func toggleExpansion(for stopID: String) {
        if expandedStopIDs.contains(stopID) {
            expandedStopIDs.remove(stopID)
        } else {
            expandedStopIDs.insert(stopID)
        }
    }

    private func synchronizeSelectionWithCurrentStops() {
        let validStopIDs = Set(allDisplayedStopIDs)

        expandedStopIDs = expandedStopIDs.intersection(validStopIDs)

        if let selectedStopID, validStopIDs.contains(selectedStopID) {
            expandedStopIDs.insert(selectedStopID)
            return
        }

        if isExternallyControlled {
            if selectedStopID != nil {
                setSelectedStopID(nil)
            }
            return
        }

        if let firstNearbyStopID = displayedNearbyStops.first?.id {
            setSelectedStopID(firstNearbyStopID)
            expandedStopIDs.insert(firstNearbyStopID)
        } else if let firstFavouriteStopID = displayedFavouriteStops.first?.id {
            setSelectedStopID(firstFavouriteStopID)
            expandedStopIDs.insert(firstFavouriteStopID)
        } else {
            setSelectedStopID(nil)
        }
    }
}

// MARK: - Bus Alert Row

struct BusAlertRow: View {
    let alert: BusAlert

    @Environment(\.themePalette) private var palette
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: alert.severity.symbolName)
                    .foregroundStyle(alertColor)
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.effect)
                        .font(.caption.bold())
                        .foregroundStyle(alertColor)
                    Text(alert.headerText)
                        .font(.caption)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }

            if isExpanded, let desc = alert.descriptionText {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.leading, 28)
            }
        }
        .padding(8)
        .background(alertColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var alertColor: Color {
        switch alert.severity {
        case .severe:  return AppTheme.danger
        case .warning: return AppTheme.warning
        case .info:    return AppTheme.info
        }
    }
}

// MARK: - Bus Stop Section

struct BusStopSection: View {
    let stop: NearbyBusStop
    let isTripDetailEnabled: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onSelectStop: () -> Void
    let onSelectDeparture: (BusDeparture) -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stop header — tappable to collapse/expand
            Button {
                onSelectStop()
                withAnimation(.easeInOut(duration: 0.25)) {
                    onToggleExpanded()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.stopName)
                            .font(.transit(17, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        if let code = stop.stopCode {
                            Text("Stop #\(code)")
                                .font(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    Spacer()
                    Text("\(stop.distanceMeters)m away")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(isSelected ? palette.buttonForeground : palette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isSelected ? palette.accent : palette.surfaceRaised)
                        .clipShape(Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                // Departure rows
                ForEach(stop.departures) { departure in
                    BusDepartureRow(
                        departure: departure,
                        isInteractive: isTripDetailEnabled
                    ) {
                        onSelectDeparture(departure)
                    }
                }
            }
        }
        .padding(12)
        .background(isSelected ? palette.surfaceRaised.opacity(0.92) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected ? palette.accentStrong.opacity(0.55) : palette.textTertiary.opacity(0.10),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(
            color: isSelected ? palette.accent.opacity(0.18) : .clear,
            radius: 8,
            y: 3
        )
    }
}

// MARK: - Bus Departure Row

struct BusDepartureRow: View {
    let departure: BusDeparture
    let isInteractive: Bool
    let onTap: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        Group {
            if isInteractive {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityHint(isInteractive ? "Shows the stops remaining on this trip." : "")
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            // Status accent strip on leading edge
            Capsule()
                .fill(statusColor)
                .frame(width: 3)
                .padding(.vertical, 4)
                .padding(.trailing, 10)

            // Route badge
            Text(departure.routeShortName)
                .font(.transit(13, weight: .heavy).monospacedDigit())
                .foregroundStyle(palette.buttonForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 44)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(palette.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: palette.accent.opacity(0.30), radius: 5, y: 2)

            // Headsign / route name
            VStack(alignment: .leading, spacing: 2) {
                Text(departure.headsign ?? departure.routeLongName)
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                timeDetailLine
            }
            .padding(.leading, 10)

            Spacer()

            // Minutes away + status badge
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(departure.minutesAway)")
                        .font(.transit(22, weight: .heavy).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                    Text("min")
                        .font(.transit(11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                }

                Text(departure.status.rawValue)
                    .font(.transit(10, weight: .bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.14), in: Capsule())
            }

            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.textTertiary)
                    .padding(.leading, 8)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var timeDetailLine: some View {
        HStack(spacing: 4) {
            Text("Sched \(departure.scheduledTime)")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)

            if let predicted = departure.predictedTime {
                Text("Pred \(predicted)")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            if departure.delaySeconds != 0 && departure.status != .noData {
                let delayStr = departure.delaySeconds > 0
                    ? "+\(departure.delaySeconds)s"
                    : "\(departure.delaySeconds)s"
                Text("Delay: \(delayStr)")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusColor: Color {
        switch departure.status {
        case .onTime:  return AppTheme.success
        case .early:   return AppTheme.info
        case .late:    return AppTheme.warning
        case .noData:  return palette.textSecondary
        case .skipped: return AppTheme.danger
        }
    }
}

private struct BusTripRequest: Identifiable {
    let provider: BusProvider
    let stopId: String
    let departure: BusDeparture

    var id: String { "\(provider.rawValue):\(departure.tripId):\(stopId):\(departure.stopSequence)" }
}

private struct BusTripDetailSheet: View {
    let request: BusTripRequest

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
                        Text("Loading trip stops…")
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
                        "Trip Detail Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "This trip pattern could not be loaded.")
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
        let selectedStop = tripDetail.stopsFromSelected.first(where: \.isSelectedStop)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(tripDetail.routeShortName)
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

            if let selectedStop {
                HStack(alignment: .top, spacing: 10) {
                    tripMetric(
                        title: "Selected Stop",
                        value: tripDetail.selectedStopName,
                        secondary: "Seq \(tripDetail.selectedStopSequence)"
                    )
                    BusStopMiniMap(stop: selectedStop)
                }
            } else {
                tripMetric(
                    title: "Selected Stop",
                    value: tripDetail.selectedStopName,
                    secondary: "Seq \(tripDetail.selectedStopSequence)"
                )
            }

            tripMetric(
                title: "Trip Continues",
                value: "\(tripDetail.remainingStopCount) more stops",
                secondary: tripDetail.earlierStopCount > 0
                    ? "Started \(tripDetail.earlierStopCount) stops earlier"
                    : "This is the first stop"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Final destination")
                    .font(.caption.bold())
                    .foregroundStyle(palette.textSecondary)
                HStack(spacing: 8) {
                    Text(tripDetail.terminalStopName)
                        .font(.transit(16, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    if let terminalTime = tripDetail.terminalScheduledTime {
                        Text(terminalTime)
                            .font(.caption.bold())
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.surfaceRaised, in: Capsule())
                    }
                    if let terminalPredictedTime = tripDetail.terminalPredictedTime {
                        Text("Pred \(terminalPredictedTime)")
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.info)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.surfaceRaised, in: Capsule())
                    }
                }
            }
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
    private func tripMetric(title: String, value: String, secondary: String) -> some View {
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

    private func loadTripDetail() async {
        isLoading = true
        errorMessage = nil
        tripDetail = nil

        do {
            tripDetail = try await providerService.fetchTripDetail(
                for: request.departure,
                stopId: request.stopId
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private var providerService: any BusDataProviding {
        switch request.provider {
        case .queenslandTransLink:
            return BusService.shared
        case .victorianPTV:
            return VictorianBusService.shared
        case .victorianTrainPTV:
            return VictorianTrainMapService.shared
        }
    }
}

private struct BusStopMiniMap: View {
    let stop: BusTripStopDetail

    @Environment(\.themePalette) private var palette

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(initialPosition: .region(region), interactionModes: []) {
                Marker(stop.stopName, coordinate: coordinate)
                    .tint(palette.accent)
            }
            .mapStyle(.standard(elevation: .flat))

            Text("Stop Map")
                .font(.caption2.bold())
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
        }
        .frame(maxWidth: .infinity, minHeight: 126, maxHeight: 126)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map showing \(stop.stopName)")
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
        case .onTime:
            return AppTheme.success
        case .early:
            return AppTheme.info
        case .late:
            return AppTheme.warning
        case .noData:
            return palette.textSecondary
        case .skipped:
            return AppTheme.danger
        }
    }
}
