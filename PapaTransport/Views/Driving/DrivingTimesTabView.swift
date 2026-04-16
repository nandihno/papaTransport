//
//  DrivingTimesTabView.swift
//  PapaTransport
//

import Combine
import SwiftUI

private enum DrivingLoadState {
    case idle
    case loading
    case loaded([DrivingTimeEstimate])
    case failed(String)

    var estimates: [DrivingTimeEstimate]? {
        if case .loaded(let results) = self { return results }
        return nil
    }
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

struct DrivingTimesTabView: View {
    @Environment(DrivingDestinationStore.self) private var store
    @AppStorage("drivingProvider") private var drivingProviderRaw = DrivingProvider.apple.rawValue
    @AppStorage("googleMapsApiKey") private var googleMapsApiKey = ""

    @State private var loadState: DrivingLoadState = .idle
    @State private var showAdd = false
    @State private var editingDestination: DrivingDestination?
    @State private var now = Date()

    private let countdownTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var provider: DrivingProvider {
        DrivingProvider(rawValue: drivingProviderRaw) ?? .apple
    }

    private var poweredByText: String {
        provider == .google ? "Powered by Google Maps" : "Powered by Apple Maps"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

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
        .task { await fetchTimes() }
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

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if store.all.isEmpty {
            emptyState
        } else {
            destinationsList
        }
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

    private var destinationsList: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 0) {
                // Provider attribution
                Text(poweredByText)
                    .font(.transit(11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 8)

                switch loadState {
                case .idle:
                    loadingPlaceholder

                case .loading:
                    if let estimates = loadState.estimates {
                        estimatesView(estimates)
                    } else {
                        loadingPlaceholder
                    }

                case .loaded(let estimates):
                    estimatesView(estimates)

                case .failed(let message):
                    errorView(message: message)
                }
            }
        }
    }

    @ViewBuilder
    private func estimatesView(_ estimates: [DrivingTimeEstimate]) -> some View {
        ForEach(Array(estimates.enumerated()), id: \.element.id) { index, estimate in
            DrivingDestinationRowView(estimate: estimate, provider: provider, now: now)
                .contextMenu {
                    Button {
                        editingDestination = estimate.destination
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteDestination(estimate.destination)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

            if index < estimates.count - 1 {
                Divider()
                    .padding(.vertical, 8)
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            ForEach(store.all) { destination in
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

    private func fetchTimes() async {
        guard !loadState.isLoading else { return }

        withAnimation { loadState = .loading }

        do {
            let results = try await DrivingTimeService.shared.fetchDrivingTimes(
                provider: provider,
                googleApiKey: googleMapsApiKey
            )
            withAnimation { loadState = .loaded(results) }
        } catch {
            withAnimation { loadState = .failed(error.localizedDescription) }
        }
    }

    private func deleteDestination(_ destination: DrivingDestination) {
        if let index = store.all.firstIndex(where: { $0.id == destination.id }) {
            store.delete(offsets: IndexSet(integer: index))
        }
    }
}
