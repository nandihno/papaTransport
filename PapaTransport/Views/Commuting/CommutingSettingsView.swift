import SwiftUI
import UserNotifications
import UIKit

struct CommutingSettingsView: View {
    @Binding var trainLineName: String
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue
    @AppStorage("victorianShowTrainCard") private var victorianShowTrainCard = true
    @AppStorage("victorianShowBusCard") private var victorianShowBusCard = false
    @State private var ptvCheckInProgress = false
    @State private var ptvCheckMessage = ""
    @State private var ptvStopCacheStatistics = PTVStopCacheStatistics.empty
    @State private var ptvStopCacheClearInProgress = false
    @State private var ptvStopCacheMessage = ""
    @AppStorage(TrainStatusNotificationService.enabledKey) private var trainStatusNotificationsEnabled = false
    @AppStorage(TrainStatusNotificationService.selectedWeekdaysKey) private var trainStatusNotificationWeekdayMask = TrainStatusNotificationService.defaultWeekdayMask
    @AppStorage(TrainStatusNotificationService.timesKey) private var trainStatusNotificationTimesRaw = TrainStatusNotificationService.encodeTimes([TrainStatusNotificationService.defaultTimeSeconds])

    // QLD home station
    @AppStorage("qldHomeStationId") private var qldHomeStationId = ""
    @AppStorage("qldHomeStation") private var qldHomeStation = ""
    @AppStorage("qldHomeStationCode") private var qldHomeStationCode = ""
    @AppStorage("qldHomeStationLat") private var qldHomeStationLat: Double = 0
    @AppStorage("qldHomeStationLon") private var qldHomeStationLon: Double = 0

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @ObservedObject private var progress = GTFSDownloadProgress.shared

    @State private var busDataReady = false
    @State private var feedValidity: GTFSFeedValidity?
    @State private var hasBundledDatabase = false
    @State private var timetableUpdateInProgress = false
    @State private var timetableUpdateMessage = ""
    @State private var busSetupMessage = ""
    @State private var busSetupInProgress = false
    @State private var showResetConfirmation = false

    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationMessage = ""
    @State private var sendingStatusNotification = false

    private var transportRegion: TransportRegion {
        TransportRegion(rawValue: transportRegionRaw) ?? .victorian
    }

    private var bundledDatabaseAvailable: Bool {
        switch transportRegion {
        case .queensland:
            true
        case .victorian:
            true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                dashboardSection

                if transportRegion == .victorian && victorianShowTrainCard {
                    victorianTrainSection
                    trainStatusNotificationSection
                }

                if transportRegion == .victorian {
                    victorianTrainDataSection
                    victorianTramSection
                    ptvTimetableAPISection
                }

                if transportRegion == .queensland && busDataReady {
                    queenslandTrainSection
                }

                transportBusSections
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await refreshBusState()
                await refreshNotificationAuthorizationStatus()
                await refreshPTVStopCacheStatistics()
            }
            .onChange(of: transportRegionRaw) { _, _ in
                Task { await refreshBusState() }
                if transportRegion != .victorian {
                    Task { await disableTrainStatusNotificationsIfUnavailable() }
                }
            }
            .onChange(of: victorianShowTrainCard) { _, isVisible in
                if !isVisible {
                    Task { await disableTrainStatusNotificationsIfUnavailable() }
                }
            }
            .onChange(of: victorianShowBusCard) { _, _ in
                Task { await refreshBusState() }
            }
            .onChange(of: trainStatusNotificationWeekdayMask) { _, mask in
                if mask == 0 {
                    notificationMessage = "Select at least one day."
                }
                Task { await TrainStatusNotificationService.shared.settingsDidChange() }
            }
            .onChange(of: trainStatusNotificationTimesRaw) { _, _ in
                Task { await TrainStatusNotificationService.shared.settingsDidChange() }
            }
            .onChange(of: trainLineName) { _, _ in
                Task {
                    if trainLineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await disableTrainStatusNotificationsIfUnavailable()
                    } else {
                        await TrainStatusNotificationService.shared.settingsDidChange()
                    }
                }
            }
        }
    }

    private var dashboardSection: some View {
        Section {
            Picker("Region", selection: $transportRegionRaw) {
                Text("Victoria").tag(TransportRegion.victorian.rawValue)
                Text("Queensland").tag(TransportRegion.queensland.rawValue)
            }
            .pickerStyle(.segmented)

            if transportRegion == .victorian {
                Toggle("Show Train Card", isOn: $victorianShowTrainCard)
                Toggle("Show Bus Card", isOn: $victorianShowBusCard)
            }
        } header: {
            Text("Commuting Dashboard")
        } footer: {
            if transportRegion == .victorian {
                Text("Choose which Victorian commuting cards appear on the main screen.")
            } else {
                Text("Queensland mode shows SEQ bus departures near your location.")
            }
        }
    }

    private var queenslandTrainSection: some View {
        Section {
            NavigationLink {
                QLDStationPickerView(
                    title: "Home Station",
                    selectedStopId: qldHomeStationId,
                    onSelect: selectQLDHomeStation
                )
            } label: {
                LabeledContent("Home Station") {
                    Text(qldHomeStation.isEmpty ? "Not set" : qldHomeStation)
                        .foregroundStyle(qldHomeStation.isEmpty ? .secondary : .primary)
                }
            }

            if !qldHomeStationId.isEmpty {
                Button(role: .destructive) {
                    clearQLDHomeStation()
                } label: {
                    Text("Clear Home Station")
                }
            }
        } header: {
            Text("Queensland Train")
        } footer: {
            Text("Your home station will be pinned as a favourite on the Trains tab, showing live departures regardless of your map position.")
        }
    }

    private func selectQLDHomeStation(_ stop: GTFSStop) {
        // Remove previous home station from favourites if it changed
        if !qldHomeStationId.isEmpty && qldHomeStationId != stop.stopId {
            FavouriteBusStopStore.shared.remove(stopId: qldHomeStationId, provider: .queenslandTrainTransLink)
        }
        // Add new station to favourites
        FavouriteBusStopStore.shared.add(FavouriteBusStop(
            provider: .queenslandTrainTransLink,
            stopId: stop.stopId,
            stopName: stop.stopName,
            stopCode: stop.stopCode,
            latitude: stop.stopLat,
            longitude: stop.stopLon
        ))
        qldHomeStationId = stop.stopId
        qldHomeStation = stop.stopName
        qldHomeStationCode = stop.stopCode ?? ""
        qldHomeStationLat = stop.stopLat
        qldHomeStationLon = stop.stopLon
    }

    private func clearQLDHomeStation() {
        if !qldHomeStationId.isEmpty {
            FavouriteBusStopStore.shared.remove(stopId: qldHomeStationId, provider: .queenslandTrainTransLink)
        }
        qldHomeStationId = ""
        qldHomeStation = ""
        qldHomeStationCode = ""
        qldHomeStationLat = 0
        qldHomeStationLon = 0
    }

    /// Only the line is configurable. Home and city station pickers used to live
    /// here, feeding a departure list that no longer exists — the Trains tab now
    /// shows stations from the visible map area instead. See UIRevampPlan.md.
    private var victorianTrainSection: some View {
        Section {
            NavigationLink {
                TrainLinePickerView(selectedLineName: $trainLineName)
            } label: {
                LabeledContent("Line") {
                    Text(trainLineName.isEmpty ? "Not set" : trainLineName)
                        .foregroundStyle(trainLineName.isEmpty ? .secondary : .primary)
                }
            }
        } header: {
            Text("Victorian Train")
        } footer: {
            Text("Sets which line's status, alerts and planned works appear on the Trains tab. Departures come from the stations in view on the map.")
        }
    }

    private var trainStatusNotificationSection: some View {
        Section {
            Toggle(
                "Train Status Notifications",
                isOn: Binding(
                    get: { trainStatusNotificationsEnabled },
                    set: { isEnabled in
                        Task { await setTrainStatusNotificationsEnabled(isEnabled) }
                    }
                )
            )
            .disabled(trainLineName.isEmpty)

            if trainStatusNotificationsEnabled {
                NavigationLink {
                    TrainNotificationScheduleView()
                } label: {
                    LabeledContent("Schedule") {
                        Text(trainNotificationScheduleSummary)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Button {
                    Task { await sendCurrentTrainStatusNotification() }
                } label: {
                    if sendingStatusNotification {
                        ProgressView()
                    } else {
                        Label("Send Current Status Now", systemImage: "paperplane.fill")
                    }
                }
                .disabled(sendingStatusNotification || trainLineName.isEmpty)
            }

            if notificationAuthorizationStatus == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Open Notification Settings", systemImage: "gearshape.fill")
                }
            }

            if !notificationMessage.isEmpty {
                Text(notificationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Train Status Notifications")
        } footer: {
            if trainLineName.isEmpty {
                Text("Select a Victorian train line before enabling timed status notifications.")
                    .foregroundStyle(.orange)
            } else if trainStatusNotificationWeekdayMask == 0 {
                Text("Open Schedule and select at least one active day.")
                    .foregroundStyle(.orange)
            } else if TrainStatusNotificationService.decodeTimes(trainStatusNotificationTimesRaw).isEmpty {
                Text("Open Schedule and add at least one notification time.")
                    .foregroundStyle(.orange)
            } else if trainStatusNotificationsEnabled {
                Text("PapaTransport checks the \(trainLineName) line near your scheduled Melbourne times. iOS controls the exact background delivery time.")
            } else {
                Text("Configure the days and times when PapaTransport should send the \(trainLineName) line status.")
            }
        }
    }

    private var trainNotificationScheduleSummary: String {
        let dayCount = (1...7).filter { trainStatusNotificationWeekdayMask & (1 << $0) != 0 }.count
        let times = TrainStatusNotificationService.decodeTimes(trainStatusNotificationTimesRaw)

        switch (dayCount, times.count) {
        case (0, _):
            return "No days"
        case (_, 0):
            return "No times"
        case (7, 1):
            return "Every day, 1 time"
        case (7, let timeCount):
            return "Every day, \(timeCount) times"
        case (1, 1):
            return "1 day, 1 time"
        case (1, let timeCount):
            return "1 day, \(timeCount) times"
        case (let dayCount, 1):
            return "\(dayCount) days, 1 time"
        default:
            return "\(dayCount) days, \(times.count) times"
        }
    }

    private var victorianTrainDataSection: some View {
        Section {
            NavigationLink {
                FavouriteBusStopsView(provider: .victorianTrainPTV)
            } label: {
                HStack {
                    Text("Favourite Stations")
                    Spacer()
                    Text("\(FavouriteBusStopStore.shared.count(for: .victorianTrainPTV))")
                        .foregroundStyle(.secondary)
                }
            }
            Label("Train stations in the visible map area are shown on the Trains tab.", systemImage: "location.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } header: {
            Text("Victorian Train")
        } footer: {
            Text("Victorian train departures and live predictions come from the PTV Timetable API.")
        }
    }

    @MainActor
    private func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await TrainStatusNotificationService.shared.notificationSettings()
    }

    @MainActor
    private func setTrainStatusNotificationsEnabled(_ isEnabled: Bool) async {
        notificationMessage = ""

        if isEnabled {
            guard !trainLineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                trainStatusNotificationsEnabled = false
                notificationMessage = "Select a Victorian train line before enabling notifications."
                return
            }

            guard trainStatusNotificationWeekdayMask != 0 else {
                trainStatusNotificationsEnabled = false
                notificationMessage = "Select at least one notification day."
                await TrainStatusNotificationService.shared.settingsDidChange()
                return
            }

            guard !TrainStatusNotificationService.decodeTimes(trainStatusNotificationTimesRaw).isEmpty else {
                trainStatusNotificationsEnabled = false
                notificationMessage = "Add at least one notification time."
                await TrainStatusNotificationService.shared.settingsDidChange()
                return
            }

            let status = await TrainStatusNotificationService.shared.requestAuthorization()
            notificationAuthorizationStatus = status

            guard status == .authorized || status == .provisional else {
                trainStatusNotificationsEnabled = false
                notificationMessage = "Notifications are disabled for PapaTransport."
                await TrainStatusNotificationService.shared.settingsDidChange()
                return
            }

            trainStatusNotificationsEnabled = true
            notificationMessage = "Timed train status checks are enabled."
        } else {
            trainStatusNotificationsEnabled = false
            notificationMessage = "Timed train status checks are disabled."
        }

        await TrainStatusNotificationService.shared.settingsDidChange()
    }

    @MainActor
    private func disableTrainStatusNotificationsIfUnavailable() async {
        guard trainStatusNotificationsEnabled else { return }
        trainStatusNotificationsEnabled = false
        await TrainStatusNotificationService.shared.settingsDidChange()
    }

    @MainActor
    private func sendCurrentTrainStatusNotification() async {
        notificationMessage = ""
        sendingStatusNotification = true
        defer { sendingStatusNotification = false }

        do {
            try await TrainStatusNotificationService.shared.sendCurrentStatusNow()
            notificationMessage = "Current train status notification sent."
        } catch {
            notificationMessage = error.localizedDescription
        }

        await refreshNotificationAuthorizationStatus()
    }


    @ViewBuilder
    private var transportBusSections: some View {
        if transportRegion == .queensland {
            queenslandBusSection
        }

        if transportRegion == .victorian && victorianShowBusCard {
            victorianBusSection
        }

        if shouldShowBusManagement {
            busManagementSection
        }
    }

    private var queenslandBusSection: some View {
        Section {
            if busDataReady {
                NavigationLink {
                    FavouriteBusStopsView(provider: .queenslandTransLink)
                } label: {
                    HStack {
                        Text("Favourite Stops")
                        Spacer()
                        Text("\(FavouriteBusStopStore.shared.count(for: .queenslandTransLink))")
                            .foregroundStyle(.secondary)
                    }
                }
                Label("Nearby stops within 300m are shown automatically.", systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                setupControls(
                    title: "Install Bundled Bus Data",
                    subtitle: "Install the bundled Queensland timetable database before browsing and saving favourite stops."
                )
            }
        } header: {
            Text("SEQ Bus")
        } footer: {
            Text("The bundled Queensland GTFS database powers nearby departures and favourite stops. Times are displayed in Queensland time (AEST, UTC+10).")
        }
    }

    private var victorianBusSection: some View {
        Section {
            NavigationLink {
                FavouriteBusStopsView(provider: .victorianPTV)
            } label: {
                HStack {
                    Text("Favourite Stops")
                    Spacer()
                    Text("\(FavouriteBusStopStore.shared.count(for: .victorianPTV))")
                        .foregroundStyle(.secondary)
                }
            }
            Label("Nearby Melbourne bus stops are shown automatically.", systemImage: "location.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } header: {
            Text("Victorian Bus")
        } footer: {
            Text("Victorian bus departures and live predictions come from the PTV Timetable API.")
        }
    }

    /// Only Queensland still ships a bundled database to manage.
    private var shouldShowBusManagement: Bool {
        transportRegion == .queensland && busDataReady
    }

    private var victorianTramSection: some View {
        Section {
            NavigationLink {
                FavouriteBusStopsView(provider: .victorianTramPTV)
            } label: {
                HStack {
                    Text("Favourite Stops")
                    Spacer()
                    Text("\(FavouriteBusStopStore.shared.count(for: .victorianTramPTV))")
                        .foregroundStyle(.secondary)
                }
            }
            Label("Nearby tram stops are shown automatically on the Trams tab.", systemImage: "location.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } header: {
            Text("Victorian Tram")
        } footer: {
            Text("Melbourne tram departures and live predictions come from the PTV Timetable API.")
        }
    }

    private var ptvTimetableAPISection: some View {
        Section {
            if PTVCredentials.isConfigured {
                LabeledContent("Credentials") {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }

                if !ptvCheckMessage.isEmpty {
                    Text(ptvCheckMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await checkPTVConnection() }
                } label: {
                    if ptvCheckInProgress {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Checking…")
                        }
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(ptvCheckInProgress)

                LabeledContent("Cached Stops") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(ptvStopCacheStatistics.stopCount)")
                        if let oldestSweepDate = ptvStopCacheStatistics.oldestSweepDate {
                            Text(oldestSweepDate, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not used yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }

                Button(role: .destructive) {
                    Task { await clearPTVStopCache() }
                } label: {
                    if ptvStopCacheClearInProgress {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Clearing…")
                        }
                    } else {
                        Label("Clear Cached Stop Data", systemImage: "trash")
                    }
                }
                .disabled(ptvStopCacheClearInProgress || ptvStopCacheStatistics.stopCount == 0)

                if !ptvStopCacheMessage.isEmpty {
                    Text(ptvStopCacheMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "No PTV credentials are embedded in this build.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("PTV Timetable API")
        } footer: {
            Text("Victorian train and bus departures are served by the official PTV Timetable API and require a network connection. Source: Licensed from Public Transport Victoria under a Creative Commons Attribution 4.0 International Licence.")
        }
    }

    @MainActor
    private func checkPTVConnection() async {
        ptvCheckInProgress = true
        ptvCheckMessage = ""
        do {
            let types = try await PTVAPIClient.shared.verifyConnection()
            ptvCheckMessage = "Connected — \(types.count) route types available."
        } catch {
            ptvCheckMessage = error.localizedDescription
        }
        ptvCheckInProgress = false
    }

    @MainActor
    private func refreshPTVStopCacheStatistics() async {
        ptvStopCacheStatistics = await PTVStopCache.shared.statistics()
    }

    @MainActor
    private func clearPTVStopCache() async {
        ptvStopCacheClearInProgress = true
        ptvStopCacheMessage = ""
        await PTVStopCache.shared.clear()
        await PTVAPIClient.shared.clearCache()
        await refreshPTVStopCacheStatistics()
        ptvStopCacheMessage = "Cached stop data was cleared."
        ptvStopCacheClearInProgress = false
    }

    private var busManagementSection: some View {
        Section {
            if let validity = feedValidity {
                LabeledContent("Timetable Covers") {
                    Text("until \(validity.displayEndDate)")
                        .foregroundStyle(feedValidityColor(validity))
                }
            }

            Button {
                Task { await checkForTimetableUpdate() }
            } label: {
                Label(
                    timetableUpdateInProgress ? "Updating…" : "Check for Timetable Update",
                    systemImage: "arrow.down.circle"
                )
            }
            .disabled(timetableUpdateInProgress)

            // Download plus import runs to tens of seconds. Without live
            // progress the row just sits there and reads as a frozen app.
            if timetableUpdateInProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .tint(palette.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(palette.accent)
                    }

                    Text(progress.detail.isEmpty
                         ? (progress.stage.isEmpty ? "Contacting TransLink…" : progress.stage)
                         : progress.detail)
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.vertical, 2)
            }

            if !timetableUpdateMessage.isEmpty {
                Text(timetableUpdateMessage)
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            }

            // Only offered when a database actually ships inside the app.
            // Shipping it is optional — without it there is nothing to
            // reinstall from, and re-downloading is the equivalent action.
            if hasBundledDatabase {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reinstall Bundled Bus Data", systemImage: "arrow.triangle.2.circlepath")
                }
                .confirmationDialog(
                    "Reinstall bundled bus data?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reinstall", role: .destructive) {
                        Task { await reinstallBusData() }
                    }
                } message: {
                    Text("This clears the installed bus database and reinstalls the copy bundled with the app.")
                }
            }

            if !busSetupMessage.isEmpty {
                Text(busSetupMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Bus Data")
        }
    }

    @ViewBuilder
    private func setupControls(title: String, subtitle: String) -> some View {
        if busSetupInProgress {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.stage.isEmpty ? "Installing bus data…" : progress.stage)
                        .font(.subheadline)
                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(subtitle, systemImage: bundledDatabaseAvailable ? "shippingbox.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(bundledDatabaseAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))

                Button {
                    Task { await installBusData() }
                } label: {
                    Label(title, systemImage: bundledDatabaseAvailable ? "shippingbox.fill" : "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if !busSetupMessage.isEmpty {
                    Text(busSetupMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func feedValidityColor(_ validity: GTFSFeedValidity) -> Color {
        switch validity.status() {
        case .current: palette.textSecondary
        case .expiringSoon: palette.warning
        case .expired, .notYetValid: palette.danger
        }
    }

    @MainActor
    private func checkForTimetableUpdate() async {
        timetableUpdateInProgress = true
        timetableUpdateMessage = ""

        let updated = await GTFSFeedRefreshService.shared.refreshIfNeeded(force: true)
        feedValidity = await GTFSDatabase.shared.feedValidity()
        await GTFSFeedStatusStore.shared.refresh()

        timetableUpdateMessage = if updated, let feedValidity {
            "Updated — now covers services until \(feedValidity.displayEndDate)."
        } else if let feedValidity, feedValidity.isUsable() {
            "Already up to date. Covers services until \(feedValidity.displayEndDate)."
        } else {
            "Could not reach TransLink. The installed timetable is unchanged."
        }
        timetableUpdateInProgress = false
    }

    @MainActor
    private func refreshBusState() async {
        guard transportRegion == .queensland || (transportRegion == .victorian && victorianShowBusCard) else {
            busDataReady = false
            busSetupInProgress = false
            busSetupMessage = ""
            return
        }

        busDataReady = await GTFSDatabase.shared.isDatabaseReady()
        feedValidity = await GTFSDatabase.shared.feedValidity()
        hasBundledDatabase = await GTFSDatabase.shared.hasBundledDatabaseAsset()
    }

    @MainActor
    private func installBusData() async {
        busSetupMessage = ""
        busSetupInProgress = true
        do {
            try await GTFSDatabase.shared.ensureReady()
            busDataReady = true
        } catch {
            busSetupMessage = "Install failed: \(error.localizedDescription)"
        }
        busSetupInProgress = false
    }

    @MainActor
    private func reinstallBusData() async {
        busSetupMessage = ""
        busSetupInProgress = true
        do {
            try await GTFSDatabase.shared.refreshDatabase()
            busDataReady = true
            busSetupMessage = "Bundled bus data was reinstalled from the app package."
        } catch {
            busSetupMessage = "Reinstall failed: \(error.localizedDescription)"
        }
        busSetupInProgress = false
    }

}
