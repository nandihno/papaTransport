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
    @AppStorage("transportMode") private var transportRegionRaw = TransportRegion.victorian.rawValue
    @AppStorage("victorianShowTrainCard") private var victorianShowTrainCard = true
    @AppStorage("victorianShowBusCard") private var victorianShowBusCard = false

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var progress = GTFSDownloadProgress.shared
    @State private var loadState: CommutingLoadState = .idle
    @State private var showSettings = false
    @State private var selectedTab = 0


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
        .placeholder(lineName: trainLineName)
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
        case 3:
            return "Trams"
        default:
            return "Plan"
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
            return "Updates every minute. Pull down to refresh or move the map."
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
            return "Updates every minute. Pull down to refresh or move the map."
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

                // Trams are Victoria-only. The tag stays 3 so Plan keeps tag 2
                // and selection is not silently reinterpreted between regions.
                if transportRegion == .victorian {
                    tramsTab
                        .tag(3)
                        .tabItem {
                            Label("Trams", systemImage: "cablecar.fill")
                        }
                }

                routePlannerTab
                    .tag(2)
                    .tabItem {
                        Label("Plan", systemImage: "map.fill")
                    }
            }
            // Reclaims vertical space while reading a departure list. The map
            // tabs are the whole screen, so the tab bar is the only chrome
            // competing with content.
            .tabBarMinimizeBehavior(.onScrollDown)
            .onChange(of: selectedTab) { _, _ in
                fetchData()
            }
            .onChange(of: transportRegion) { _, newRegion in
                // The Trams tab disappears outside Victoria; leaving it selected
                // would show an empty TabView.
                if newRegion != .victorian && selectedTab == 3 {
                    selectedTab = 0
                }
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
                                .foregroundStyle(palette.accentText)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                CommutingSettingsView(trainLineName: $trainLineName)
            }
        }
        .screenTheme(AppTheme.transport)
        // Picks up the remaining built-in text styles (.caption, .subheadline …)
        // so they match the rounded design baked into the transit* roles.
        .fontDesign(.rounded)
        .task { await performFetch() }
        .task(id: transportRegion) { await refreshQueenslandTimetableIfNeeded() }
    }

    // MARK: - Map Tab

    private var mapTab: some View {
        GTFSProvisioningGate(region: transportRegion) {
            busTabContent
        }
    }

    private var busTabContent: some View {
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
        GTFSProvisioningGate(region: transportRegion) {
            trainsTabContent
        }
    }

    private var trainsTabContent: some View {
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

    // MARK: - Trams Tab

    private var tramsTab: some View {
        BusMapExplorerView(
            provider: .victorianTramPTV,
            onOpenSettings: { showSettings = true },
            onRefresh: { await performFetch() },
            autoRefreshEnabled: selectedTab == 3,
            statusMessage: nil,
            statusDetail: nil
        )
    }

    // MARK: - Route Planner Tab

    private var routePlannerTab: some View {
        RoutePlannerView()
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
            .font(.transitCaption)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)

        case .loaded(let snapshot):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.success)
                Text("Last updated at \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.transitCaption)
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
                        .font(.transitLabel)
                        .foregroundStyle(palette.textPrimary)
                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.transitCaption)
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

    /// The Queensland timetable is a local database with a fixed validity
    /// window; this tops it up in the background as it approaches expiry so it
    /// never silently runs out. No-op for Victoria, which is served live by
    /// the PTV API.
    private func refreshQueenslandTimetableIfNeeded() async {
        guard transportRegion == .queensland else { return }
        let updated = await GTFSFeedRefreshService.shared.refreshIfNeeded()
        if updated {
            await performFetch()
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
                    .font(.transitHeadline)
                    .foregroundStyle(palette.accentText)

                Text("No commute cards are enabled for the current region.")
                    .font(.transitCaption)
                    .foregroundStyle(palette.textPrimary)

                Text("Open Settings to choose which transport cards should appear.")
                    .font(.transitCaption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }
}
