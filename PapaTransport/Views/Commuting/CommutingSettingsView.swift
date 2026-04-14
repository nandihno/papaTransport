import SwiftUI

struct CommutingSettingsView: View {
    @Binding var trainLineName: String
    @AppStorage("homeStation") private var homeStation = ""
    @AppStorage("cityStation") private var cityStation = "Flinders Street"
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue
    @AppStorage("victorianShowTrainCard") private var victorianShowTrainCard = true
    @AppStorage("victorianShowBusCard") private var victorianShowBusCard = false
    @AppStorage(VictorianBusService.realtimeAPIKeyDefaultsKey) private var victorianGTFSRealtimeApiKey = ""

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var progress = GTFSDownloadProgress.shared

    @State private var busDataReady = false
    @State private var busSetupMessage = ""
    @State private var busSetupInProgress = false
    @State private var showResetConfirmation = false

    @State private var trainDataReady = false
    @State private var trainSetupMessage = ""
    @State private var trainSetupInProgress = false
    @State private var showTrainResetConfirmation = false

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
                }

                if transportRegion == .victorian {
                    victorianTrainDataSection
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
                await refreshTrainState()
            }
            .onChange(of: transportRegionRaw) { _, _ in
                Task { await refreshBusState() }
                Task { await refreshTrainState() }
            }
            .onChange(of: victorianShowBusCard) { _, _ in
                Task { await refreshBusState() }
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

            NavigationLink {
                StationPickerView(title: "Home Station", selectedStation: $homeStation)
            } label: {
                LabeledContent("Home Station") {
                    Text(homeStation.isEmpty ? "Not set" : homeStation)
                        .foregroundStyle(homeStation.isEmpty ? .secondary : .primary)
                }
            }
            .disabled(trainLineName.isEmpty)

            NavigationLink {
                StationPickerView(title: "City Station", selectedStation: $cityStation)
            } label: {
                LabeledContent("City Station") {
                    Text(cityStation.isEmpty ? "Not set" : cityStation)
                        .foregroundStyle(cityStation.isEmpty ? .secondary : .primary)
                }
            }
            .disabled(trainLineName.isEmpty)
        } header: {
            Text("Victorian Train")
        } footer: {
            if trainLineName.isEmpty {
                Text("Select a train line first to enable station selection.")
                    .foregroundStyle(.orange)
            } else {
                Text("Choose the line plus your home and city stations for the train card.")
            }
        }
    }

    private var victorianTrainDataSection: some View {
        Section {
            if trainDataReady {
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
                Label("Nearby stations within 2km are shown automatically on the Trains tab.", systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showTrainResetConfirmation = true
                } label: {
                    Label("Reinstall Bundled Train Data", systemImage: "arrow.triangle.2.circlepath")
                }
                .confirmationDialog(
                    "Reinstall bundled train data?",
                    isPresented: $showTrainResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reinstall", role: .destructive) {
                        Task { await reinstallTrainData() }
                    }
                } message: {
                    Text("This clears the installed cached train database and reinstalls the bundled copy from the app package.")
                }
            } else {
                trainSetupControls
            }

            if !trainSetupMessage.isEmpty {
                Text(trainSetupMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Victorian Train")
        } footer: {
            Text("The bundled Victorian train GTFS database powers nearby station departures. Live predictions use the same Transport Victoria realtime key configured below.")
        }
    }

    @ViewBuilder
    private var trainSetupControls: some View {
        if trainSetupInProgress {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.stage.isEmpty ? "Installing train data…" : progress.stage)
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
                Label("Install the bundled Victorian train timetable database to enable the station map and departures.", systemImage: "shippingbox.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await installTrainData() }
                } label: {
                    Label("Install Bundled Train Data", systemImage: "shippingbox.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
            LabeledContent("Realtime API Key") {
                TextField("Ocp-Apim key", text: $victorianGTFSRealtimeApiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }

            if victorianGTFSRealtimeApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Scheduled departures still work without this key. Add it to unlock live late and early predictions.", systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if busDataReady {
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
                Label("Nearby Melbourne bus stops are available after the bundled database is installed.", systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                setupControls(
                    title: "Install Bundled Bus Data",
                    subtitle: "Install the bundled Victorian timetable database before browsing and saving favourite stops."
                )
            }
        } header: {
            Text("Victorian Bus")
        } footer: {
            Text("The bundled Victorian GTFS database powers nearby departures and favourite stops. Live predictions come from the Transport Victoria GTFS-RT bus feed when a realtime key is configured.")
        }
    }

    private var shouldShowBusManagement: Bool {
        switch transportRegion {
        case .queensland:
            busDataReady
        case .victorian:
            victorianShowBusCard && busDataReady
        }
    }

    private var busManagementSection: some View {
        Section {
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
                Text("This clears the installed cached bus database and reinstalls the bundled copy from the app package.")
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

    @MainActor
    private func refreshBusState() async {
        guard transportRegion == .queensland || (transportRegion == .victorian && victorianShowBusCard) else {
            busDataReady = false
            busSetupInProgress = false
            busSetupMessage = ""
            return
        }

        switch transportRegion {
        case .queensland:
            busDataReady = await GTFSDatabase.shared.isDatabaseReady()
        case .victorian:
            busDataReady = await VictorianBusGTFSDatabase.shared.isDatabaseReady()
        }
    }

    @MainActor
    private func installBusData() async {
        busSetupMessage = ""
        busSetupInProgress = true
        do {
            switch transportRegion {
            case .queensland:
                try await GTFSDatabase.shared.ensureReady()
            case .victorian:
                try await VictorianBusGTFSDatabase.shared.ensureReady()
            }
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
            switch transportRegion {
            case .queensland:
                try await GTFSDatabase.shared.refreshDatabase()
            case .victorian:
                try await VictorianBusGTFSDatabase.shared.refreshDatabase()
            }
            busDataReady = true
            busSetupMessage = "Bundled bus data was reinstalled from the app package."
        } catch {
            busSetupMessage = "Reinstall failed: \(error.localizedDescription)"
        }
        busSetupInProgress = false
    }

    // MARK: - Train Data

    @MainActor
    private func refreshTrainState() async {
        guard transportRegion == .victorian else {
            trainDataReady = false
            trainSetupInProgress = false
            trainSetupMessage = ""
            return
        }
        trainDataReady = await VictorianTrainGTFSDatabase.shared.isDatabaseReady()
    }

    @MainActor
    private func installTrainData() async {
        trainSetupMessage = ""
        trainSetupInProgress = true
        do {
            try await VictorianTrainGTFSDatabase.shared.ensureReady()
            trainDataReady = true
        } catch {
            trainSetupMessage = "Install failed: \(error.localizedDescription)"
        }
        trainSetupInProgress = false
    }

    @MainActor
    private func reinstallTrainData() async {
        trainSetupMessage = ""
        trainSetupInProgress = true
        do {
            try await VictorianTrainGTFSDatabase.shared.refreshDatabase()
            trainDataReady = true
            trainSetupMessage = "Bundled train data was reinstalled from the app package."
        } catch {
            trainSetupMessage = "Reinstall failed: \(error.localizedDescription)"
        }
        trainSetupInProgress = false
    }
}
