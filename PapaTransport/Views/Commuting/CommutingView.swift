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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    fetchButton
                    statusBanner
                    gtfsProgressBanner
                    cardsStack
                }
                .padding()
            }
            .refreshable { await performFetch() }
            .navigationTitle("Commuting")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                CommutingSettingsView(trainLineName: $trainLineName)
            }
        }
        .screenTheme(AppTheme.transport)
    }

    private var fetchButton: some View {
        Button(action: fetchData) {
            HStack(spacing: 8) {
                if loadState.isLoading {
                    ProgressView()
                        .tint(Color.black.opacity(0.82))
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(loadState.isLoading ? "Fetching…" : "Fetch commuting")
            }
        }
        .buttonStyle(TransitPrimaryButtonStyle())
        .disabled(loadState.isLoading)
        .opacity(loadState.isLoading ? 0.84 : 1)
        .animation(.easeInOut(duration: 0.2), value: loadState.isLoading)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch loadState {
        case .idle:
            Label {
                Text("Tap **Fetch commuting** to load train and bus departures.")
            } icon: {
                Image(systemName: "hand.tap")
            }
            .font(.transit(13, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)

        case .loading:
            EmptyView()

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

    private var cardsStack: some View {
        VStack(spacing: 20) {
            if shouldShowTrainCard {
                TrainCard(train: loadState.snapshot?.trainInfo ?? placeholderTrainInfo)
            }

            if shouldShowBusCard {
                BusCard(busInfo: loadState.snapshot?.busInfo ?? placeholderBusInfo)
            }

            if !shouldShowTrainCard && !shouldShowBusCard {
                CommuteConfigurationCard()
            }
        }
        .redacted(reason: loadState.isLoaded ? [] : .placeholder)
        .opacity(loadState.isIdle ? 0.58 : 1)
        .animation(.spring(duration: 0.45), value: loadState.isLoaded)
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
            includeTrain: shouldShowTrainCard,
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
