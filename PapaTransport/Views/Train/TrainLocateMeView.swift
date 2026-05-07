import CoreLocation
import SwiftUI

struct TrainLocateMeView: View {
    @AppStorage("trainLineName") private var savedTrainLineName = ""
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue

    @Environment(\.themePalette) private var palette
    @StateObject private var tracker = TrainLocationTracker()

    @State private var routes: [LocateTrainRoute] = []
    @State private var selectedLineName = ""
    @State private var directionOverride = TrainLocateDirectionOverride.automatic
    @State private var result: TrainLocateResult?
    @State private var errorMessage: String?
    @State private var isResolving = false
    @State private var isLoadingRoutes = false
    @State private var locateTask: Task<Void, Never>?

    private var transportRegion: TransportRegion {
        TransportRegion(rawValue: transportRegionRaw) ?? .victorian
    }

    private var lineNameForLookup: String {
        let manual = selectedLineName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        guard transportRegion == .victorian else { return "" }
        return savedTrainLineName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var defaultLinePickerTitle: String {
        if transportRegion == .victorian, !savedTrainLineName.isEmpty {
            return "Saved: \(savedTrainLineName)"
        }
        return "Auto detect"
    }

    private var lineHelperText: String {
        switch transportRegion {
        case .victorian:
            return "Choose your train line if you know it. This helps in places where several lines use the same tracks."
        case .queensland:
            return "Choose your train line if you know it. Leave this on Auto detect if you are not sure."
        }
    }

    private var directionHelperText: String {
        switch transportRegion {
        case .victorian:
            return "City means travelling towards Flinders Street. Away means travelling out from the city."
        case .queensland:
            return "Leave this on Auto unless PapaTransport is unsure. Direction 1 and Direction 2 come from the Queensland timetable."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlsCard
                statusContent
            }
            .padding()
        }
        .refreshable {
            await resolveCurrentLocation()
        }
        .task {
            selectedLineName = transportRegion == .victorian ? savedTrainLineName : ""
            await loadRoutes()
            tracker.start()
        }
        .onDisappear {
            locateTask?.cancel()
            tracker.stop()
        }
        .onReceive(tracker.$currentLocation) { location in
            guard let location else { return }
            resolve(location: location)
        }
        .onChange(of: selectedLineName) { _, _ in
            resolve(location: tracker.currentLocation)
        }
        .onChange(of: directionOverride) { _, _ in
            resolve(location: tracker.currentLocation)
        }
        .onChange(of: transportRegionRaw) { _, _ in
            selectedLineName = transportRegion == .victorian ? savedTrainLineName : ""
            result = nil
            errorMessage = nil
            routes = []
            Task {
                await loadRoutes()
                resolve(location: tracker.currentLocation)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if let result {
            resultCard(result)
            detailCard(result)
            if result.confidence != .high || !result.candidateSummaries.isEmpty {
                candidatesCard(result.candidateSummaries)
            }
        } else if let errorMessage = errorMessage ?? tracker.errorMessage {
            unavailableCard(title: "Could not work out where you are", message: errorMessage)
        } else {
            waitingCard
        }
    }

    private var controlsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Label("Locate Me", systemImage: "location.north.line.fill")
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.accent)

                    Spacer()

                    Button {
                        Task { await resolveCurrentLocation() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                    }
                    .disabled(isResolving)
                    .accessibilityLabel("Refresh location")
                }

                Picker("Line", selection: $selectedLineName) {
                    Text(defaultLinePickerTitle).tag("")
                    ForEach(routes) { route in
                        Text(route.routeShortName).tag(route.routeShortName)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isLoadingRoutes)

                helperText(lineHelperText)

                Picker("Direction", selection: $directionOverride) {
                    ForEach(TrainLocateDirectionOverride.allCases) { direction in
                        Text(directionTitle(direction)).tag(direction)
                    }
                }
                .pickerStyle(.segmented)

                helperText(directionHelperText)

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

                    if isResolving {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .font(.transit(12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func resultCard(_ result: TrainLocateResult) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: result.isAtStation ? "tram.circle.fill" : "location.north.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(confidenceColor(result.confidence))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.primaryMessage)
                            .font(.transit(26, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(result.nextStationMessage)
                            .font(.transit(18, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let minutes = result.minutesToNextStation, let nextStation = result.nextStationName {
                    Label("About \(minutes) min to \(nextStation)", systemImage: "clock.fill")
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

    private func detailCard(_ result: TrainLocateResult) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("What this means")
                    .font(.transit(17, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                metricRow(
                    "Train line",
                    result.lineName,
                    explanation: "The service PapaTransport thinks you are on.",
                    systemImage: "tram.fill"
                )
                metricRow(
                    "Travelling",
                    "\(result.directionText) · ends at \(result.terminalStationName)",
                    explanation: "The general direction of the train and where this service ends.",
                    systemImage: "arrow.up.right"
                )
                metricRow(
                    "Destination shown",
                    result.headsign,
                    explanation: "The destination text normally shown for this train service.",
                    systemImage: "signpost.right.fill"
                )

                if let previous = result.previousStationName {
                    metricRow(
                        "Last station",
                        previous,
                        explanation: "The station PapaTransport thinks the train has already passed.",
                        systemImage: "arrow.backward.circle.fill"
                    )
                }

                if let next = result.nextStationName {
                    let timing = [result.nextStationPredictedTime, result.nextStationScheduledTime]
                        .compactMap { $0 }
                        .first
                    metricRow(
                        "Next station",
                        timing.map { "\(next) at about \($0)" } ?? next,
                        explanation: "The next station in the timetable for the train PapaTransport matched.",
                        systemImage: "arrow.forward.circle.fill"
                    )
                }

                metricRow(
                    "How sure",
                    "\(result.confidence.rawValue) · \(Int(result.confidenceScore.rounded()))%",
                    explanation: "Higher means your location, the timetable, and the train route line up well.",
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
                    "about \(result.distanceFromTrackMeters)m",
                    explanation: "How far your phone location is from the estimated train route between stations.",
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

    private func candidatesCard(_ summaries: [TrainLocateCandidateSummary]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Other possible trains")
                    .font(.transit(17, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                helperText("Shown when more than one train could match your location. The percentage shows how likely each match looks.")

                ForEach(summaries) { summary in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(summary.lineName) · \(summary.directionText)")
                                .font(.transit(14, weight: .semibold))
                                .foregroundStyle(palette.textPrimary)
                            Text(summary.headsign)
                                .font(.transit(12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Text("\(Int(summary.score.rounded()))%")
                            .font(.transit(13, weight: .bold))
                            .foregroundStyle(palette.accent)
                    }

                    if summary.id != summaries.last?.id {
                        Divider().overlay(palette.textTertiary.opacity(0.25))
                    }
                }
            }
        }
    }

    private var waitingCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Working out where you are…")
                        .font(.transit(17, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                }

                Text("PapaTransport is comparing your phone location with the train timetable and nearby stations.")
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
                .frame(maxWidth: 150, alignment: .trailing)
        }
    }

    private func helperText(_ text: String) -> some View {
        Text(text)
            .font(.transit(12, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func directionTitle(_ direction: TrainLocateDirectionOverride) -> String {
        guard transportRegion == .queensland else { return direction.displayName }

        switch direction {
        case .automatic:
            return "Auto"
        case .outbound:
            return "Direction 1"
        case .inbound:
            return "Direction 2"
        }
    }

    private func confidenceColor(_ confidence: TrainLocateConfidence) -> Color {
        switch confidence {
        case .high:
            return AppTheme.success
        case .medium:
            return AppTheme.warning
        case .low:
            return AppTheme.danger
        }
    }

    @MainActor
    private func loadRoutes() async {
        guard routes.isEmpty else { return }
        isLoadingRoutes = true
        defer { isLoadingRoutes = false }

        do {
            switch transportRegion {
            case .victorian:
                routes = try await VictorianTrainLocatorService.shared.availableRoutes().map {
                    LocateTrainRoute(
                        routeId: $0.routeId,
                        routeShortName: $0.routeShortName,
                        routeLongName: $0.routeLongName
                    )
                }
            case .queensland:
                routes = try await QueenslandTrainLocationService.shared.availableRoutes().map {
                    LocateTrainRoute(
                        routeId: $0.routeId,
                        routeShortName: $0.routeShortName,
                        routeLongName: $0.routeLongName
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func resolveCurrentLocation() async {
        if let location = tracker.currentLocation {
            await performResolve(location: location)
        } else {
            tracker.start()
        }
    }

    private func resolve(location: CLLocation?) {
        guard let location else { return }
        locateTask?.cancel()
        locateTask = Task {
            await performResolve(location: location)
        }
    }

    @MainActor
    private func performResolve(location: CLLocation) async {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }

        do {
            let located: TrainLocateResult
            switch transportRegion {
            case .victorian:
                located = try await VictorianTrainLocatorService.shared.locate(
                    location: location,
                    selectedLineName: lineNameForLookup,
                    directionOverride: directionOverride
                )
            case .queensland:
                located = try await QueenslandTrainLocationService.shared.locate(
                    location: location,
                    selectedLineName: lineNameForLookup,
                    directionOverride: directionOverride
                )
            }

            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.35)) {
                result = located
            }
        } catch {
            guard !Task.isCancelled else { return }
            result = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct LocateTrainRoute: Identifiable {
    let routeId: String
    let routeShortName: String
    let routeLongName: String

    var id: String { routeId }
}
