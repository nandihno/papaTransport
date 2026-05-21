//
//  DrivingTimesTabView.swift
//  PapaTransport
//

import Combine
import EventKit
import SwiftUI
import UIKit

private enum DrivingLoadState {
    case idle
    case loading(previous: [DrivingTimeEstimate]?)
    case loaded([DrivingTimeEstimate])
    case failed(String)

    var estimates: [DrivingTimeEstimate]? {
        if case .loaded(let results) = self { return results }
        if case .loading(let previous) = self { return previous }
        return nil
    }
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

struct DrivingTimesTabView: View {
    @Environment(\.themePalette) private var palette
    @Environment(DrivingDestinationStore.self) private var store
    @AppStorage("drivingProvider") private var drivingProviderRaw = DrivingProvider.apple.rawValue
    @AppStorage("googleMapsApiKey") private var googleMapsApiKey = ""

    let autoRefreshEnabled: Bool

    @State private var loadState: DrivingLoadState = .idle
    @State private var lastCheckedAt: Date?
    @State private var showAdd = false
    @State private var editingDestination: DrivingDestination?
    @State private var swipedDestinationID: DrivingDestination.ID?
    @State private var now = Date()
    @State private var calendarDestinations: [DrivingDestination] = []
    @State private var calendarAuthStatus: EKAuthorizationStatus = CalendarDestinationService.shared.authorizationStatus

    private let countdownTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let calendarChangedPublisher = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
    private static let autoRefreshInterval: Duration = .seconds(60)

    init(autoRefreshEnabled: Bool = true) {
        self.autoRefreshEnabled = autoRefreshEnabled
    }

    private var provider: DrivingProvider {
        DrivingProvider(rawValue: drivingProviderRaw) ?? .apple
    }

    private var poweredByText: String {
        provider == .google ? "Powered by Google Maps" : "Powered by Apple Maps"
    }

    private var isCalendarAuthorized: Bool {
        if #available(iOS 17.0, *) {
            return calendarAuthStatus == .fullAccess || calendarAuthStatus == .authorized
        }
        return calendarAuthStatus == .authorized
    }

    private var combinedDestinations: [DrivingDestination] {
        calendarDestinations + store.all
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                refreshStatusCard
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                Divider()
                    .padding(.horizontal)

                contentArea
                    .padding()
            }
        }
        .refreshable { await fetchTimes() }
        .sheet(isPresented: $showAdd) {
            AddDrivingDestinationView()
                .environment(store)
        }
        .sheet(item: $editingDestination) { destination in
            EditDrivingDestinationView(destination: destination)
                .environment(store)
        }
        .onReceive(countdownTimer) { tick in
            now = tick
        }
        .onReceive(calendarChangedPublisher) { _ in
            Task { await refreshCalendarAndTimes() }
        }
        .task {
            await loadCalendarDestinations()
            await fetchTimes()
        }
        .task(id: autoRefreshEnabled) {
            await runAutoRefreshLoop()
        }
        .onChange(of: store.all.count) { _, _ in
            Task { await fetchTimes() }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Label("Driving Times", systemImage: "car.fill")
                .font(.transit(20, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 12) {
                // Refresh button
                Button {
                    Task { await fetchTimes() }
                } label: {
                    Image(systemName: loadState.isLoading ? "arrow.clockwise" : "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .rotationEffect(.degrees(loadState.isLoading ? 360 : 0))
                        .animation(
                            loadState.isLoading
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: loadState.isLoading
                        )
                }
                .disabled(loadState.isLoading)

                // Add destination button
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var refreshStatusCard: some View {
        if loadState.isLoading || lastCheckedAt != nil {
            HStack(spacing: 10) {
                Image(systemName: loadState.isLoading ? "arrow.triangle.2.circlepath" : "clock.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(refreshStatusTitle)
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    Text(refreshStatusDetail)
                        .font(.transit(12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if loadState.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(12)
            .background(palette.mutedPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.accentStrong.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var refreshStatusTitle: String {
        if loadState.isLoading {
            return "Refreshing driving times…"
        }

        if let lastCheckedAt {
            return "Last checked at \(lastCheckedAt.formatted(date: .omitted, time: .shortened))"
        }

        return "Driving times not checked yet"
    }

    private var refreshStatusDetail: String {
        if loadState.isLoading {
            return "Checking current travel times from your phone location."
        }

        return "Updates automatically every minute while this tab is open. Pull down or tap refresh to check now."
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            calendarBanner

            if combinedDestinations.isEmpty {
                emptyState
            } else {
                destinationsList
            }
        }
    }

    @ViewBuilder
    private var calendarBanner: some View {
        switch calendarAuthStatus {
        case .notDetermined:
            calendarPromptCard
        case .denied, .restricted:
            calendarDeniedCard
        default:
            EmptyView()
        }
    }

    private var calendarPromptCard: some View {
        Button {
            Task {
                _ = await CalendarDestinationService.shared.requestAccess()
                calendarAuthStatus = CalendarDestinationService.shared.authorizationStatus
                await refreshCalendarAndTimes()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Show today's calendar events")
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Suggest events with a location as driving destinations.")
                        .font(.transit(12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(12)
            .background(palette.mutedPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.accentStrong.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var calendarDeniedCard: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar access disabled")
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Enable it in Settings to surface today's calendar events as destinations.")
                        .font(.transit(12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(12)
            .background(palette.mutedPanelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.warning.opacity(0.24), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("No Destinations Yet")
                    .font(.transit(18, weight: .bold))
                Text("Tap + to add your first destination and see live driving times from your current location.")
                    .font(.transit(14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showAdd = true
            } label: {
                Label("Add Destination", systemImage: "plus")
            }
            .buttonStyle(TransitPrimaryButtonStyle())
            .padding(.top, 4)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var destinationsList: some View {
        VStack(alignment: .trailing, spacing: 6) {
            CardContainer {
                VStack(alignment: .leading, spacing: 0) {
                    switch loadState {
                    case .idle:
                        loadingPlaceholder

                    case .loading:
                        if let estimates = loadState.estimates {
                            estimatesView(orderedEstimates(estimates))
                        } else {
                            loadingPlaceholder
                        }

                    case .loaded(let estimates):
                        estimatesView(orderedEstimates(estimates))

                    case .failed(let message):
                        errorView(message: message)
                    }
                }
            }

            Text(poweredByText)
                .font(.transit(11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
        }
    }

    private func orderedEstimates(_ estimates: [DrivingTimeEstimate]) -> [DrivingTimeEstimate] {
        let calendar = estimates.filter { $0.destination.isCalendarSourced }
        let saved = estimates.filter { !$0.destination.isCalendarSourced }
        return calendar + saved
    }

    @ViewBuilder
    private func estimatesView(_ estimates: [DrivingTimeEstimate]) -> some View {
        ForEach(Array(estimates.enumerated()), id: \.element.id) { index, estimate in
            SwipeableDrivingDestinationRowView(
                estimate: estimate,
                provider: provider,
                now: now,
                allowSwipeActions: !estimate.destination.isCalendarSourced,
                isOpen: Binding(
                    get: { swipedDestinationID == estimate.destination.id },
                    set: { swipedDestinationID = $0 ? estimate.destination.id : nil }
                )
            ) {
                editingDestination = estimate.destination
            } onDelete: {
                deleteDestination(estimate.destination)
            }

            if index < estimates.count - 1 {
                Divider()
                    .padding(.vertical, 8)
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            ForEach(combinedDestinations) { destination in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 120, height: 18)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 180, height: 13)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 60, height: 28)
                }
                .redacted(reason: .placeholder)
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
            Text(message)
                .font(.transit(13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    @MainActor
    private func fetchTimes() async {
        guard !loadState.isLoading else { return }

        let previousEstimates = loadState.estimates
        let destinations = combinedDestinations
        withAnimation { loadState = .loading(previous: previousEstimates) }

        do {
            let results = try await DrivingTimeService.shared.fetchDrivingTimes(
                provider: provider,
                googleApiKey: googleMapsApiKey,
                destinations: destinations
            )

            if Task.isCancelled, let previousEstimates {
                withAnimation { loadState = .loaded(previousEstimates) }
                return
            }

            let cancelledResults = !results.isEmpty
                && results.allSatisfy { $0.errorMessage == "Route lookup cancelled." }
            if cancelledResults, let previousEstimates {
                withAnimation { loadState = .loaded(previousEstimates) }
                return
            }

            withAnimation { loadState = .loaded(results) }
            lastCheckedAt = Date()
        } catch {
            if let previousEstimates {
                withAnimation { loadState = .loaded(previousEstimates) }
            } else {
                withAnimation { loadState = .failed(error.localizedDescription) }
            }
        }
    }

    private func runAutoRefreshLoop() async {
        guard autoRefreshEnabled else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: Self.autoRefreshInterval)
            guard !Task.isCancelled, autoRefreshEnabled else { return }
            await loadCalendarDestinations()
            await fetchTimes()
        }
    }

    @MainActor
    private func loadCalendarDestinations() async {
        calendarAuthStatus = CalendarDestinationService.shared.authorizationStatus
        guard isCalendarAuthorized else {
            if !calendarDestinations.isEmpty { calendarDestinations = [] }
            return
        }
        let fetched = await CalendarDestinationService.shared.fetchUpcomingTodayDestinations()
        if fetched != calendarDestinations {
            calendarDestinations = fetched
        }
    }

    @MainActor
    private func refreshCalendarAndTimes() async {
        await loadCalendarDestinations()
        await fetchTimes()
    }

    private func deleteDestination(_ destination: DrivingDestination) {
        if let index = store.all.firstIndex(where: { $0.id == destination.id }) {
            store.delete(offsets: IndexSet(integer: index))
        }
    }
}

private struct SwipeableDrivingDestinationRowView: View {
    let estimate: DrivingTimeEstimate
    let provider: DrivingProvider
    let now: Date
    let allowSwipeActions: Bool
    @Binding var isOpen: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.themePalette) private var palette
    @GestureState private var dragTranslation: CGFloat = 0

    private let actionWidth: CGFloat = 152

    private var currentOffset: CGFloat {
        guard allowSwipeActions else { return 0 }
        let baseOffset = isOpen ? -actionWidth : 0
        return min(0, max(-actionWidth, baseOffset + dragTranslation))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if allowSwipeActions {
                actionButtons
                    .opacity(currentOffset < -8 ? 1 : 0)
                    .allowsHitTesting(isOpen)
            }

            destinationRow
        }
        .clipped()
        .animation(.snappy(duration: 0.2), value: isOpen)
    }

    @ViewBuilder
    private var destinationRow: some View {
        let base = DrivingDestinationRowView(estimate: estimate, provider: provider, now: now)
            .background {
                if currentOffset < -1 {
                    palette.cardBackground
                }
            }
            .offset(x: currentOffset)

        if allowSwipeActions {
            base.gesture(swipeGesture)
        } else {
            base
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isOpen = false
                }
                onEdit()
            } label: {
                swipeActionLabel(title: "Edit", systemImage: "pencil")
            }
            .buttonStyle(.plain)
            .frame(width: actionWidth / 2)
            .background(AppTheme.info)

            Button(role: .destructive) {
                withAnimation(.snappy(duration: 0.2)) {
                    isOpen = false
                }
                onDelete()
            } label: {
                swipeActionLabel(title: "Delete", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .frame(width: actionWidth / 2)
            .background(AppTheme.danger)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func swipeActionLabel(title: String, systemImage: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
            Text(title)
                .font(.transit(12, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                let baseOffset = isOpen ? -actionWidth : 0
                let finalOffset = min(0, max(-actionWidth, baseOffset + value.translation.width))
                let shouldOpen = value.predictedEndTranslation.width < -actionWidth / 2
                    || value.translation.width < -actionWidth / 3
                let shouldClose = value.predictedEndTranslation.width > actionWidth / 3
                    || value.translation.width > actionWidth / 4

                if shouldOpen {
                    isOpen = true
                } else if shouldClose {
                    isOpen = false
                } else {
                    isOpen = finalOffset < -actionWidth / 2
                }
            }
    }
}
