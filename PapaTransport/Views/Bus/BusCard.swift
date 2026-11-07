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
    let emptyStateMessageOverride: String?
    let mapSelection: MapDepartureSelection?
    let onSelectMapDeparture: ((BusDeparture, String) -> Void)?
    let revealID: UUID?

    private let selectedStopIDBinding: Binding<String?>?
    /// When the host owns trip presentation, this card raises the request
    /// instead of presenting its own sheet. Two `.sheet` modifiers in one
    /// subtree — the card's and the map explorer's — competed for presentation
    /// and left the map's own controls unable to open theirs.
    private let selectedTripBinding: Binding<BusTripRequest?>?

    @Environment(\.themePalette) private var palette
    @State private var localSelectedTripRequest: BusTripRequest?
    @State private var localSelectedStopID: String?
    @State private var expandedStopIDs: Set<String> = []

    init(
        title: String = "Departures",
        busInfo: BusInfo,
        selectedStopID: Binding<String?>? = nil,
        selectedTrip: Binding<BusTripRequest?>? = nil,
        mapSelection: MapDepartureSelection? = nil,
        onSelectMapDeparture: ((BusDeparture, String) -> Void)? = nil,
        showsNearby: Bool = true,
        showsFavourites: Bool = true,
        emptyStateMessageOverride: String? = nil,
        revealID: UUID? = nil
    ) {
        self.title = title
        self.busInfo = busInfo
        self.selectedStopIDBinding = selectedStopID
        self.selectedTripBinding = selectedTrip
        self.mapSelection = mapSelection
        self.onSelectMapDeparture = onSelectMapDeparture
        self.showsNearby = showsNearby
        self.showsFavourites = showsFavourites
        self.emptyStateMessageOverride = emptyStateMessageOverride
        self.revealID = revealID
    }

    private func selectTrip(_ request: BusTripRequest) {
        if let onSelectMapDeparture {
            onSelectMapDeparture(request.departure, request.stopId)
        } else if let selectedTripBinding {
            selectedTripBinding.wrappedValue = request
        } else {
            localSelectedTripRequest = request
        }
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

    private var hasUnavailableDepartureData: Bool {
        (displayedNearbyStops + displayedFavouriteStops).contains {
            $0.departureDataAvailability == .unavailable
        }
    }

    private var hasDisplayedDepartures: Bool {
        (displayedNearbyStops + displayedFavouriteStops).contains { !$0.departures.isEmpty }
    }

    private var isExternallyControlled: Bool {
        selectedStopIDBinding != nil
    }

    private var vehicleIconName: String {
        busInfo.provider.symbolName
    }

    private var nearbySubjectNoun: String {
        busInfo.provider.stopsNoun
    }

    private var nearbySearchRadiusDescription: String {
        switch busInfo.provider {
        case .queenslandTrainTransLink, .victorianTrainPTV: return "5km"
        case .victorianTramPTV: return "250m"
        default: return "300m"
        }
    }

    private var emptyStateMessage: String {
        if let emptyStateMessageOverride {
            return emptyStateMessageOverride
        }

        if showsFavourites {
            return "No saved favourite \(busInfo.provider.stopsNoun) currently have departures."
        }

        return "No \(nearbySubjectNoun) found within \(nearbySearchRadiusDescription) of the map center. Pan the map to search elsewhere."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: vehicleIconName)
                    .font(.transitHeadline)
                    .foregroundStyle(palette.accentText)
                Spacer()
                Text(busInfo.localTimeAtFetch)
                    .font(.transitBadge)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.surfaceRaised, in: Capsule())
            }

            if busInfo.locationAvailable && hasDisplayedDepartures {
                Label("Tap a departure to see where that trip continues.", systemImage: "list.bullet.rectangle.portrait")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            if busInfo.locationAvailable && hasUnavailableDepartureData {
                Label(
                    "Cached stop locations are shown. Live departures are unavailable until a connection returns.",
                    systemImage: "wifi.slash"
                )
                .font(.caption)
                .foregroundStyle(palette.warning)
            }

            if !busInfo.locationAvailable {
                Label("Location unavailable. Enable Location Services to see nearby \(nearbySubjectNoun).",
                      systemImage: "location.slash.fill")
                    .font(.subheadline)
                    .foregroundStyle(palette.warning)
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
                            mapSelection: mapSelection,
                            highlightsRoute: onSelectMapDeparture != nil,
                            onToggleExpanded: {
                                toggleExpansion(for: stop.id)
                            },
                            onSelectStop: {
                                setSelectedStopID(stop.id)
                            }
                        ) { departure in
                            selectTrip(BusTripRequest(
                                provider: busInfo.provider,
                                stopId: stop.id,
                                departure: departure
                            ))
                        }
                        .id("stop:\(stop.id)")
                    }
                }

                if !displayedFavouriteStops.isEmpty {
                    if !displayedNearbyStops.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    Label("Favourites", systemImage: "star.fill")
                        .font(.caption.bold())
                        .foregroundStyle(palette.accentText)
                    ForEach(displayedFavouriteStops) { stop in
                        BusStopSection(
                            stop: stop,
                            isTripDetailEnabled: true,
                            isSelected: selectedStopID == stop.id,
                            isExpanded: expandedStopIDs.contains(stop.id),
                            mapSelection: mapSelection,
                            highlightsRoute: onSelectMapDeparture != nil,
                            onToggleExpanded: {
                                toggleExpansion(for: stop.id)
                            },
                            onSelectStop: {
                                setSelectedStopID(stop.id)
                            }
                        ) { departure in
                            selectTrip(BusTripRequest(
                                provider: busInfo.provider,
                                stopId: stop.id,
                                departure: departure
                            ))
                        }
                        .id("stop:favourite:\(stop.id)")
                    }
                }
            }
        }
        // Flat, no card chrome: this only ever renders inside the bus/tram
        // sheet, which is already the container. See UIRevampPlan.md §2.5.
        .padding(.horizontal, 4)
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
        .onChange(of: revealID) { _, _ in
            if let selectedStopID, allDisplayedStopIDs.contains(selectedStopID) {
                expandedStopIDs.insert(selectedStopID)
            }
        }
        .sheet(item: selectedTripBinding == nil ? $localSelectedTripRequest : .constant(nil)) { request in
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
            // The host validates the union of nearby and favourite stops.
            // This card cannot invalidate a selection in its sibling card.
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
        case .severe:  return palette.danger
        case .warning: return palette.warning
        case .info:    return palette.info
        }
    }
}

// MARK: - Bus Stop Section

struct BusStopSection: View {
    let stop: NearbyBusStop
    let isTripDetailEnabled: Bool
    let isSelected: Bool
    let isExpanded: Bool
    var mapSelection: MapDepartureSelection? = nil
    var highlightsRoute: Bool = false
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
                            .font(.transitHeadline)
                            .foregroundStyle(palette.textPrimary)
                        if let code = stop.stopCode {
                            Text("Stop #\(code)")
                                .font(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    Spacer()
                    Text(formattedStopDistance(stop.distanceMeters))
                        .font(.transitBadge)
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

                if stop.departureDataAvailability == .unavailable {
                    Label(
                        "Departures unavailable. Check your connection and refresh.",
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                } else {
                    // Departure rows
                    ForEach(stop.departures) { departure in
                        DepartureRow(
                            departure: departure,
                            isInteractive: isTripDetailEnabled,
                            isSelected: mapSelection?.matches(departure, at: stop.id) == true,
                            highlightsRoute: highlightsRoute
                        ) {
                            onSelectDeparture(departure)
                        }
                    }
                }
            }
        }
        // Selected stops get a tint; unselected ones sit flat with a hairline,
        // matching TrainStationSection. See UIRevampPlan.md §2.5.
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(
            isSelected ? palette.surfaceRaised.opacity(0.55) : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            if !isSelected {
                Rectangle()
                    .fill(palette.textTertiary.opacity(0.14))
                    .frame(height: 1)
            }
        }
    }
}

/// Internal rather than private: the map explorer opens this sheet too,
/// when a live vehicle pin is tapped.
struct BusTripRequest: Identifiable {
    let provider: BusProvider
    let stopId: String
    let departure: BusDeparture

    var id: String { "\(provider.rawValue):\(departure.tripId):\(stopId):\(departure.stopSequence)" }
}

struct BusTripDetailSheet: View {
    let request: BusTripRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var tripDetail: BusTripDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPriorStops = false

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
                            if !tripDetail.stopsBeforeSelected.isEmpty {
                                priorStopsCard(tripDetail)
                            }
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
                    .font(.transitTitle.monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.84))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(tripDetail.headsign ?? tripDetail.routeLongName)
                        .font(.transitHeadline)
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
                        .font(.transitHeadline)
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
                            .foregroundStyle(palette.info)
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
    private func priorStopsCard(_ tripDetail: BusTripDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showPriorStops.toggle()
                }
            } label: {
                HStack {
                    Text(showPriorStops ? "Stops Before Here" : "\(tripDetail.stopsBeforeSelected.count) stops before here")
                        .font(.transitHeadline)
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Image(systemName: showPriorStops ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if showPriorStops {
                ForEach(Array(tripDetail.stopsBeforeSelected.enumerated()), id: \.element.id) { index, stop in
                    TripStopRow(
                        stop: stop,
                        isLast: index == tripDetail.stopsBeforeSelected.count - 1
                    )
                }
                .opacity(0.55)
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
                .font(.transitHeadline)
                .foregroundStyle(palette.textPrimary)

            ForEach(Array(tripDetail.stopsFromSelected.enumerated()), id: \.element.id) { index, stop in
                TripStopRow(
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
                .font(.transitBody)
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
        case .queenslandTrainTransLink:
            return QLDTrainMapService.shared
        case .victorianPTV:
            return PTVBoardService.victorianBus
        case .victorianTrainPTV:
            return PTVBoardService.victorianTrain
        case .victorianTramPTV:
            return PTVBoardService.victorianTram
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
                .glassEffect(.regular, in: .capsule)
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
