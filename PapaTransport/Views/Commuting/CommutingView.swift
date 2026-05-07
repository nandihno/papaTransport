import SwiftUI

private enum CommutingLoadState {
    case idle
    case loading
    case loaded(CommutingSnapshot)

    var snapshot: CommutingSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

struct CommutingView: View {
    @AppStorage("trainLineName") private var trainLineName = ""
    @AppStorage("homeStation") private var homeStation = ""
    @AppStorage("cityStation") private var cityStation = "Flinders Street"
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue
    @AppStorage("victorianShowTrainCard") private var victorianShowTrainCard = true
    @AppStorage("victorianShowBusCard") private var victorianShowBusCard = false

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var progress = GTFSDownloadProgress.shared
    @State private var loadState: CommutingLoadState = .idle
    @State private var showSettings = false
    @State private var selectedTab = 0

    private var drivingStore: DrivingDestinationStore { DrivingDestinationStore.shared }

    private var transportRegion: TransportRegion {
        TransportRegion(rawValue: transportRegionRaw) ?? .victorian
    }

    private var shouldShowTrainCard: Bool {
        switch transportRegion {
        case .victorian:
            victorianShowTrainCard
        case .queensland:
            false
        }
    }

    private var shouldShowBusCard: Bool {
        switch transportRegion {
        case .victorian:
            victorianShowBusCard
        case .queensland:
            true
        }
    }

    private var palette: ThemePalette {
        AppTheme.transport.palette(for: colorScheme)
    }

    private var placeholderTrainInfo: TrainInfo {
        .placeholder(lineName: trainLineName, homeStation: homeStation, cityStation: cityStation)
    }

    private var placeholderBusInfo: BusInfo {
        BusInfo.placeholder(
            provider: transportRegion == .queensland ? .queenslandTransLink : .victorianPTV
        )
    }

    private var busProvider: BusProvider {
        transportRegion == .queensland ? .queenslandTransLink : .victorianPTV
    }

    private var usesImmersiveMapLayout: Bool {
        if selectedTab == 2 || selectedTab == 3 { return false }
        if selectedTab == 0 {
            return shouldShowBusCard
        }
        return true
    }

    private var navigationTitle: String {
        switch selectedTab {
        case 0:
            return "Bus"
        case 1:
            return "Trains"
        case 2:
            return "Locate"
        default:
            return "Driving"
        }
    }

    private var busStatusMessage: String? {
        switch loadState {
        case .idle:
            return nil
        case .loading:
            return "Refreshing nearby departures…"
        case .loaded(let snapshot):
            return "Last checked at \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var busStatusDetail: String? {
        switch loadState {
        case .idle:
            return nil
        case .loading:
            return "Looking for current departures near your map position."
        case .loaded:
            return "Updates automatically every minute while this tab is open. Pull down or move the map to check a different area."
        }
    }

    private var trainStatusMessage: String? {
        switch loadState {
        case .idle:
            return nil
        case .loading:
            return "Refreshing train information…"
        case .loaded(let snapshot):
            return "Last checked at \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var trainStatusDetail: String? {
        switch loadState {
        case .idle:
            return nil
        case .loading:
            return "Updating line status, planned works, and nearby station departures."
        case .loaded:
            return "Updates automatically every minute while this tab is open. Pull down or move the map to check a different area."
        }
    }

    private var gtfsProgressStage: String? {
        progress.isActive ? progress.stage : nil
    }

    private var gtfsProgressDetail: String? {
        progress.isActive && !progress.detail.isEmpty ? progress.detail : nil
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                mapTab
                    .tag(0)
                    .tabItem {
                        Label("Bus", systemImage: "bus.fill")
                    }

                trainsTab
                    .tag(1)
                    .tabItem {
                        Label("Trains", systemImage: "tram.fill")
                    }

                locateTab
                    .tag(2)
                    .tabItem {
                        Label("Locate", systemImage: "location.north.line.fill")
                    }

                drivingTab
                    .tag(3)
                    .tabItem {
                        Label("Driving", systemImage: "car.fill")
                    }
            }
            .onChange(of: selectedTab) { _, _ in
                fetchData()
            }
            .onChange(of: showSettings) { _, isPresented in
                if !isPresented {
                    fetchData()
                }
            }
            .toolbar(usesImmersiveMapLayout ? .hidden : .visible, for: .navigationBar)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(selectedTab == 0 ? .large : .inline)
            .toolbar {
                if !usesImmersiveMapLayout {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(palette.accent)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                CommutingSettingsView(trainLineName: $trainLineName)
            }
        }
        .screenTheme(AppTheme.transport)
        .task { await performFetch() }
    }

    // MARK: - Map Tab

    private var mapTab: some View {
        Group {
            if shouldShowBusCard {
                BusMapExplorerView(
                    provider: busProvider,
                    initialBusInfo: loadState.snapshot?.busInfo,
                    onOpenSettings: { showSettings = true },
                    onRefresh: { await performFetch() },
                    autoRefreshEnabled: selectedTab == 0,
                    statusMessage: busStatusMessage,
                    statusDetail: busStatusDetail,
                    progressStage: gtfsProgressStage,
                    progressDetail: gtfsProgressDetail
                )
                .redacted(reason: loadState.isLoaded ? [] : .placeholder)
                .opacity(loadState.isIdle ? 0.58 : 1)
                .animation(.spring(duration: 0.45), value: loadState.isLoaded)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        statusBanner
                        gtfsProgressBanner
                        CommuteConfigurationCard()
                    }
                    .padding()
                }
                .refreshable { await performFetch() }
            }
        }
    }

    // MARK: - Trains Tab

    private var trainsTab: some View {
        Group {
            if transportRegion == .victorian {
                TrainMapExplorerView(
                    provider: .victorianTrainPTV,
                    trainInfo: loadState.snapshot?.trainInfo ?? placeholderTrainInfo,
                    onOpenSettings: { showSettings = true },
                    onRefresh: { await performFetch() },
                    autoRefreshEnabled: selectedTab == 1,
                    statusMessage: trainStatusMessage,
                    statusDetail: trainStatusDetail
                )
            } else {
                TrainMapExplorerView(
                    provider: .queenslandTrainTransLink,
                    onOpenSettings: { showSettings = true },
                    onRefresh: { await performFetch() },
                    autoRefreshEnabled: selectedTab == 1,
                    statusMessage: trainStatusMessage,
                    statusDetail: trainStatusDetail
                )
            }
        }
    }

    // MARK: - Locate Tab

    private var locateTab: some View {
        LocateContainerView(transportRegion: transportRegion)
    }

    // MARK: - Driving Tab

    private var drivingTab: some View {
        DrivingTimesTabView(autoRefreshEnabled: selectedTab == 3)
            .environment(drivingStore)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch loadState {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.85)
                Text("Loading…")
            }
            .font(.transit(13, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)

        case .loaded(let snapshot):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
                Text("Last updated at \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.transit(12, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var gtfsProgressBanner: some View {
        if progress.isActive {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.stage)
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.transit(12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(palette.mutedPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.accentStrong.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func fetchData() {
        Task { await performFetch() }
    }

    private func performFetch() async {
        guard !loadState.isLoading else { return }

        let previousState = loadState
        if !loadState.isLoaded {
            withAnimation {
                loadState = .loading
            }
        }

        let snapshot = await CommutingService.shared.fetchSnapshot(
            trainLineName: trainLineName,
            homeStation: homeStation,
            cityStation: cityStation,
            transportRegion: transportRegion,
            includeTrain: transportRegion == .victorian,
            includeBus: shouldShowBusCard
        )

        withAnimation(.spring(duration: 0.5)) {
            loadState = .loaded(snapshot)
        }

        if loadState.snapshot == nil {
            withAnimation {
                loadState = previousState
            }
        }
    }
}

private struct CommuteConfigurationCard: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Label("Commuting", systemImage: "car.2.fill")
                    .font(.transit(18, weight: .bold))
                    .foregroundStyle(palette.accent)

                Text("No commute cards are enabled for the current region.")
                    .font(.transit(14, weight: .medium))
                    .foregroundStyle(palette.textPrimary)

                Text("Open Settings to choose which transport cards should appear.")
                    .font(.transit(12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }
}
