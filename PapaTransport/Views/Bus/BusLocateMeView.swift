import CoreLocation
import SwiftUI

struct BusLocateMeView: View {
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue

    @Environment(\.themePalette) private var palette
    @StateObject private var tracker = TrainLocationTracker()

    @State private var phase: Phase = .pickingStop
    @State private var nearbyStops: [BusLocateNearbyStop] = []
    @State private var selectedStop: BusLocateNearbyStop?
    @State private var session: BusLocateSession?
    @State private var result: BusLocateResult?
    @State private var errorMessage: String?
    @State private var isLoadingNearby = false
    @State private var isResolving = false
    @State private var locateTask: Task<Void, Never>?
    @State private var lastNearbyFetchLocation: CLLocation?

    private var transportRegion: TransportRegion {
        TransportRegion(rawValue: transportRegionRaw) ?? .victorian
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if transportRegion != .victorian {
                    queenslandUnsupportedCard
                } else {
                    headerCard
                    content
                }
            }
            .padding()
        }
        .refreshable {
            await refreshForCurrentPhase()
        }
        .task {
            tracker.start()
        }
        .onDisappear {
            locateTask?.cancel()
            tracker.stop()
        }
        .onReceive(tracker.$currentLocation) { location in
            guard let location else { return }
            handleLocationUpdate(location)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickingStop:
            stopPickerSection
        case .pickingRoute:
            routePickerSection
        case .tracking:
            trackingSection
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Label("Bus Locate Me", systemImage: "bus.fill")
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.accent)

                    Spacer()

                    Button {
                        Task { await refreshForCurrentPhase() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                    }
                    .disabled(isResolving || isLoadingNearby)
                    .accessibilityLabel("Refresh")
                }

                phaseIndicator

                HStack(spacing: 8) {
                    if tracker.isTracking {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(AppTheme.success)
                        Text("Updating while this tab is open")
                    } else {
                        Image(systemName: "location.slash.fill")
                            .foregroundStyle(AppTheme.warning)
                        Text("Waiting for your phone location")
                    }

                    Spacer()

                    if isResolving || isLoadingNearby {
                        ProgressView().scaleEffect(0.8)
                    }
                }
                .font(.transit(12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var phaseIndicator: some View {
        HStack(spacing: 6) {
            stepBadge(number: 1, label: "Stop", isActive: phase == .pickingStop, isComplete: phase != .pickingStop)
            stepConnector(filled: phase != .pickingStop)
            stepBadge(number: 2, label: "Route", isActive: phase == .pickingRoute, isComplete: phase == .tracking)
            stepConnector(filled: phase == .tracking)
            stepBadge(number: 3, label: "Track", isActive: phase == .tracking, isComplete: false)
        }
    }

    private func stepBadge(number: Int, label: String, isActive: Bool, isComplete: Bool) -> some View {
        let bg: Color = isComplete ? AppTheme.success : (isActive ? palette.accent : palette.textTertiary.opacity(0.3))
        let fg: Color = (isActive || isComplete) ? .white : palette.textSecondary
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(bg).frame(width: 22, height: 22)
                if isComplete {
                    Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption2.bold()).foregroundStyle(fg)
                }
            }
            Text(label)
                .font(.transit(12, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? palette.textPrimary : palette.textSecondary)
        }
    }

    private func stepConnector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? AppTheme.success : palette.textTertiary.opacity(0.3))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Stop picker

    private var stopPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick your bus stop")
                        .font(.transit(17, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    helperText("These are bus stops within 300 m of your phone. Pick the one you are boarding from.")
                }
            }

            if let errorMessage = errorMessage ?? tracker.errorMessage {
                unavailableCard(title: "Could not find nearby stops", message: errorMessage)
            } else if isLoadingNearby && nearbyStops.isEmpty {
                waitingCard(text: "Looking for nearby bus stops…")
            } else if nearbyStops.isEmpty {
                CardContainer {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No bus stops within 300 m", systemImage: "mappin.slash")
                            .font(.transit(15, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        helperText("Walk closer to a bus stop, then pull down to refresh.")
                    }
                }
            } else {
                ForEach(nearbyStops) { stop in
                    stopRow(stop)
                }
            }
        }
    }

    private func stopRow(_ stop: BusLocateNearbyStop) -> some View {
        Button {
            selectedStop = stop
            phase = .pickingRoute
            errorMessage = nil
        } label: {
            CardContainer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(stop.stopName)
                            .font(.transit(15, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Text("\(Int(stop.distanceMeters.rounded())) m")
                            .font(.transit(13, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                    }

                    if let code = stop.stopCode {
                        Text("Stop ID \(code)")
                            .font(.transit(11, weight: .medium))
                            .foregroundStyle(palette.textTertiary)
                    }

                    let routes = uniqueRouteShortNames(stop.routes)
                    if !routes.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(routes, id: \.self) { name in
                                    Text(name)
                                        .font(.transit(12, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(palette.accent.opacity(0.18))
                                        .foregroundStyle(palette.accent)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func uniqueRouteShortNames(_ routes: [BusLocateRouteAtStop]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for route in routes where !route.routeShortName.isEmpty && !seen.contains(route.routeShortName) {
            seen.insert(route.routeShortName)
            ordered.append(route.routeShortName)
        }
        return ordered
    }

    // MARK: - Route picker

    private var routePickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pick your bus route")
                                .font(.transit(17, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            if let stop = selectedStop {
                                Text("Boarding at \(stop.stopName)")
                                    .font(.transit(12, weight: .medium))
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        Spacer()
                        Button("Change stop") {
                            phase = .pickingStop
                            selectedStop = nil
                            errorMessage = nil
                        }
                        .font(.transit(12, weight: .semibold))
                    }
                    helperText("Each row is a route in a specific direction. Pick the one you are boarding.")
                }
            }

            if let stop = selectedStop {
                ForEach(stop.routes) { route in
                    routeRow(stop: stop, route: route)
                }
            }
        }
    }

    private func routeRow(stop: BusLocateNearbyStop, route: BusLocateRouteAtStop) -> some View {
        Button {
            startTracking(stop: stop, route: route)
        } label: {
            CardContainer {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(route.routeShortName.isEmpty ? "Bus" : route.routeShortName)
                        .font(.transit(18, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("→ \(route.displayHeadsign)")
                            .font(.transit(14, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(route.routeLongName)
                            .font(.transit(11, weight: .medium))
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tracking

    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                resultCard(result)
                detailCard(result)
            } else if let errorMessage = errorMessage ?? tracker.errorMessage {
                unavailableCard(title: "Could not work out your bus", message: errorMessage)
            } else {
                waitingCard(text: "Working out where your bus is…")
            }

            CardContainer {
                HStack {
                    Button("Change stop") {
                        resetToStopPicker()
                    }
                    .font(.transit(13, weight: .semibold))
                    Spacer()
                    if let session {
                        Button("Change route") {
                            resetToRoutePicker(session: session)
                        }
                        .font(.transit(13, weight: .semibold))
                    }
                }
            }
        }
    }

    private func resultCard(_ result: BusLocateResult) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: result.isAtStop ? "bus.doubledecker.fill" : "location.north.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(confidenceColor(result.confidence))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.primaryMessage)
                            .font(.transit(24, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(result.nextStopMessage)
                            .font(.transit(17, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let minutes = result.minutesToNextStop, let next = result.nextStopName {
                    Label("About \(minutes) min to \(next)", systemImage: "clock.fill")
                        .font(.transit(15, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                }

                if let warning = result.warningMessage {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.transit(13, weight: .medium))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func detailCard(_ result: BusLocateResult) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("What this means")
                    .font(.transit(17, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                metricRow(
                    "Bus route",
                    "\(result.routeShortName) → \(result.headsign)",
                    explanation: "The bus service PapaTransport thinks you are on.",
                    systemImage: "bus.fill"
                )
                metricRow(
                    "Boarded at",
                    result.boardingStopName,
                    explanation: "The stop you said you boarded from.",
                    systemImage: "figure.wave"
                )
                metricRow(
                    "Final stop",
                    result.terminalStopName,
                    explanation: "Where this trip ends in the timetable.",
                    systemImage: "flag.checkered"
                )

                if let previous = result.previousStopName {
                    metricRow(
                        "Last stop",
                        previous,
                        explanation: "The stop PapaTransport thinks the bus has already passed.",
                        systemImage: "arrow.backward.circle.fill"
                    )
                }

                if let next = result.nextStopName {
                    let timing = [result.nextStopPredictedTime, result.nextStopScheduledTime]
                        .compactMap { $0 }
                        .first
                    metricRow(
                        "Next stop",
                        timing.map { "\(next) at about \($0)" } ?? next,
                        explanation: "The next stop in the timetable for the bus PapaTransport matched.",
                        systemImage: "arrow.forward.circle.fill"
                    )
                }

                metricRow(
                    "How sure",
                    "\(result.confidence.rawValue) · \(Int(result.confidenceScore.rounded()))%",
                    explanation: "Higher means your location, the timetable, and the bus route line up well.",
                    systemImage: "gauge.with.dots.needle.bottom.50percent"
                )
                metricRow(
                    "Phone location",
                    "within about \(result.accuracyMeters)m",
                    explanation: "How accurate your phone says the current location reading is.",
                    systemImage: "scope"
                )
                metricRow(
                    "Distance from route",
                    "about \(result.distanceFromRouteMeters)m",
                    explanation: "How far your phone location is from the bus route between stops.",
                    systemImage: "ruler"
                )
                metricRow(
                    "Last checked",
                    result.lastUpdated.formatted(date: .omitted, time: .shortened),
                    explanation: "When this estimate was last refreshed.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
    }

    private func waitingCard(text: String) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(text)
                        .font(.transit(17, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                }

                Text("PapaTransport is comparing your phone location with the bus timetable and nearby stops.")
                    .font(.transit(13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unavailableCard(title: String, message: String) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.transit(17, weight: .bold))
                    .foregroundStyle(AppTheme.warning)

                Text(message)
                    .font(.transit(13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var queenslandUnsupportedCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Label("Bus Locate is Victoria-only for now", systemImage: "info.circle.fill")
                    .font(.transit(17, weight: .bold))
                    .foregroundStyle(palette.accent)
                Text("Switch to Victoria in Settings to use Bus Locate, or use the Train tab for Queensland.")
                    .font(.transit(13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricRow(
        _ title: String,
        _ value: String,
        explanation: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.accent)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.transit(13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(explanation)
                    .font(.transit(11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(value)
                .font(.transit(13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170, alignment: .trailing)
        }
    }

    private func helperText(_ text: String) -> some View {
        Text(text)
            .font(.transit(12, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func confidenceColor(_ confidence: BusLocateConfidence) -> Color {
        switch confidence {
        case .high:
            return AppTheme.success
        case .medium:
            return AppTheme.warning
        case .low:
            return AppTheme.danger
        }
    }

    // MARK: - Phase transitions

    private func startTracking(stop: BusLocateNearbyStop, route: BusLocateRouteAtStop) {
        let newSession = BusLocateSession(
            boardingStopId: stop.stopId,
            boardingStopName: stop.stopName,
            routeId: route.routeId,
            routeShortName: route.routeShortName,
            directionId: route.directionId,
            headsign: route.headsign,
            lockedTripId: nil
        )
        session = newSession
        result = nil
        errorMessage = nil
        phase = .tracking
        if let location = tracker.currentLocation {
            resolveBusLocation(location: location)
        }
    }

    private func resetToStopPicker() {
        locateTask?.cancel()
        phase = .pickingStop
        selectedStop = nil
        session = nil
        result = nil
        errorMessage = nil
        if let location = tracker.currentLocation {
            Task { await loadNearbyStops(location: location) }
        }
    }

    private func resetToRoutePicker(session: BusLocateSession) {
        locateTask?.cancel()
        result = nil
        errorMessage = nil
        if let stop = nearbyStops.first(where: { $0.stopId == session.boardingStopId }) {
            selectedStop = stop
            phase = .pickingRoute
        } else {
            // The previously chosen stop is no longer in the nearby list — fall back.
            resetToStopPicker()
        }
    }

    // MARK: - Location handling

    private func handleLocationUpdate(_ location: CLLocation) {
        switch phase {
        case .pickingStop:
            // Re-fetch nearby stops only if we have moved meaningfully or have nothing yet.
            if shouldRefetchNearby(for: location) {
                Task { await loadNearbyStops(location: location) }
            }
        case .pickingRoute:
            break
        case .tracking:
            resolveBusLocation(location: location)
        }
    }

    private func shouldRefetchNearby(for location: CLLocation) -> Bool {
        guard !isLoadingNearby else { return false }
        guard let last = lastNearbyFetchLocation else { return true }
        return location.distance(from: last) > 30
    }

    @MainActor
    private func refreshForCurrentPhase() async {
        switch phase {
        case .pickingStop:
            if let location = tracker.currentLocation {
                await loadNearbyStops(location: location)
            } else {
                tracker.start()
            }
        case .pickingRoute:
            break
        case .tracking:
            if let location = tracker.currentLocation {
                resolveBusLocation(location: location)
            }
        }
    }

    @MainActor
    private func loadNearbyStops(location: CLLocation) async {
        isLoadingNearby = true
        errorMessage = nil
        defer { isLoadingNearby = false }

        do {
            let stops = try await VictorianBusLocatorService.shared.nearbyStopsWithRoutes(location: location)
            lastNearbyFetchLocation = location
            withAnimation(.spring(duration: 0.3)) {
                nearbyStops = stops
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveBusLocation(location: CLLocation) {
        guard let session else { return }
        locateTask?.cancel()
        locateTask = Task { await performResolve(location: location, session: session) }
    }

    @MainActor
    private func performResolve(location: CLLocation, session: BusLocateSession) async {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }

        do {
            let outcome = try await VictorianBusLocatorService.shared.locate(
                location: location,
                session: session
            )

            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.35)) {
                result = outcome.result
            }
            self.session = outcome.session
        } catch {
            guard !Task.isCancelled else { return }
            result = nil
            errorMessage = error.localizedDescription
        }
    }
}

private enum Phase {
    case pickingStop
    case pickingRoute
    case tracking
}
