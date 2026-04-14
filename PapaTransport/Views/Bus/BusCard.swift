//
//  BusCard.swift
//  myLatest
//

import SwiftUI
import MapKit

// MARK: - Bus Card

struct BusCard: View {
    let busInfo: BusInfo
    @Environment(\.themePalette) private var palette
    @State private var selectedTripRequest: BusTripRequest?

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Label("Bus Departures", systemImage: "bus.fill")
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Spacer()
                    Text(busInfo.localTimeAtFetch)
                        .font(.transit(11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.surfaceRaised, in: Capsule())
                }

                if busInfo.locationAvailable {
                    Label("Tap a departure to see where that trip continues.", systemImage: "list.bullet.rectangle.portrait")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }

                if !busInfo.locationAvailable {
                    Label("Location unavailable. Enable Location Services to see nearby bus stops.",
                          systemImage: "location.slash.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.warning)
                } else if busInfo.nearbyStops.isEmpty && busInfo.favouriteStops.isEmpty {
                    Label("No bus stops found within 300m. Add favourite stops in Settings.",
                          systemImage: "mappin.slash")
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                } else {
                    // Alerts
                    ForEach(busInfo.alerts) { alert in
                        BusAlertRow(alert: alert)
                    }

                    // Nearby stops with departures
                    if !busInfo.nearbyStops.isEmpty {
                        Label("Nearby", systemImage: "location.fill")
                            .font(.caption.bold())
                            .foregroundStyle(palette.textSecondary)
                            .padding(.top, 4)
                        ForEach(busInfo.nearbyStops) { stop in
                            BusStopSection(
                                stop: stop,
                                isTripDetailEnabled: true
                            ) { departure in
                                selectedTripRequest = BusTripRequest(
                                    provider: busInfo.provider,
                                    stopId: stop.id,
                                    departure: departure
                                )
                            }
                        }
                    }

                    // Favourite stops
                    if !busInfo.favouriteStops.isEmpty {
                        if !busInfo.nearbyStops.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                        }
                        Label("Favourites", systemImage: "star.fill")
                            .font(.caption.bold())
                            .foregroundStyle(palette.accent)
                        ForEach(busInfo.favouriteStops) { stop in
                            BusStopSection(
                                stop: stop,
                                isTripDetailEnabled: true
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
        }
        .sheet(item: $selectedTripRequest) { request in
            BusTripDetailSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
    let onSelectDeparture: (BusDeparture) -> Void

    @Environment(\.themePalette) private var palette
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stop header — tappable to collapse/expand
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
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
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.surfaceRaised)
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
        HStack(spacing: 10) {
            // Route badge
            Text(departure.routeShortName)
                .font(.transit(14, weight: .heavy).monospacedDigit())
                .foregroundStyle(Color.black.opacity(0.84))
                .frame(minWidth: 42)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(palette.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Headsign / route name
            VStack(alignment: .leading, spacing: 1) {
                Text(departure.headsign ?? departure.routeLongName)
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                timeDetailLine
            }

            Spacer()

            // Minutes away + status
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(departure.minutesAway)")
                        .font(.transit(24, weight: .heavy).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                    Text("min")
                        .font(.transit(12, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                }
                Text(departure.status.rawValue)
                    .font(.transit(12, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(.vertical, 2)
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
