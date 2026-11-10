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
        TabView(selection: $selectedTab) {
            Tab("Bus", systemImage: "bus.fill", value: 0) {
                tabScreen("Bus") { mapTab }
            }

            Tab("Trains", systemImage: "tram.fill", value: 1) {
                tabScreen("Trains") { trainsTab }
            }

            if transportRegion == .victorian {
                Tab("Trams", systemImage: "cablecar.fill", value: 3) {
                    tabScreen("Trams") { tramsTab }
                }
            }

            Tab("Plan", systemImage: "map.fill", value: 2) {
                tabScreen("Plan a trip") { RoutePlannerView() }
            }
        }
        .onChange(of: selectedTab) { _, _ in
            fetchData()
        }
        .onChange(of: transportRegion) { _, newRegion in
            if newRegion != .victorian && selectedTab == 3 {
                selectedTab = 0
            }
        }
        .onChange(of: showSettings) { _, isPresented in
            if !isPresented {
                fetchData()
            }
        }
        .sheet(isPresented: $showSettings) {
            CommutingSettingsView(trainLineName: $trainLineName)
        }
        .screenTheme(AppTheme.transport)
        // Picks up the remaining built-in text styles (.caption, .subheadline …)
        // so they match the rounded design baked into the transit* roles.
        .fontDesign(.rounded)
        .task { await performFetch() }
        .task(id: transportRegion) { await refreshQueenslandTimetableIfNeeded() }
    }

    private func tabScreen<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
        }
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
                busConfiguration
            }
        }
    }

    private var busConfiguration: some View {
        GeometryReader { proxy in
            let bounds = busConfigurationBounds(in: proxy)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CommuteConfigurationCard(onOpenSettings: { showSettings = true })
                    statusBanner
                    gtfsProgressBanner
                }
                .padding(16)
                .frame(maxWidth: 440, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await performFetch() }
            .frame(width: bounds.width, height: bounds.height)
            .padding(.top, bounds.minY)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.screenBackground.ignoresSafeArea())
    }

    private func busConfigurationBounds(in proxy: GeometryProxy) -> CGRect {
        let bounds = CGRect(origin: .zero, size: proxy.size)
        guard #available(iOS 27.1, *),
              let fold = proxy.reservedRegions(kind: .division).first else { return bounds }

        if fold.frame.height > fold.frame.width {
            let width = max(0, min(bounds.width, fold.frame.minX - fold.margins.leading))
            return CGRect(x: 0, y: 0, width: width, height: bounds.height)
        }

        let top = max(0, min(bounds.height, fold.frame.maxY + fold.margins.bottom))
        return CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
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
                    onRefresh: { await performFetch() },
                    autoRefreshEnabled: selectedTab == 1,
                    statusMessage: trainStatusMessage,
                    statusDetail: trainStatusDetail
                )
            } else {
                TrainMapExplorerView(
                    provider: .queenslandTrainTransLink,
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
            onRefresh: { await performFetch() },
            autoRefreshEnabled: selectedTab == 3,
            statusMessage: nil,
            statusDetail: nil
        )
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
    let onOpenSettings: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Label("Bus departures are off", systemImage: "bus.fill")
                    .font(.transitHeadline)
                    .foregroundStyle(palette.accentText)
                    .accessibilityAddTraits(.isHeader)

                Text("Turn on the bus card in Settings to explore stops and see upcoming departures.")
                    .font(.transitBody)
                    .foregroundStyle(palette.textSecondary)

                Button("Open Settings", systemImage: "gearshape", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
