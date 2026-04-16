import SwiftUI

/// Searchable picker for Queensland GTFS train stations.
/// Queries GTFSDatabase (the same database used for QLD buses/trains) and
/// returns one result per physical station, deduplicated by parent_station.
struct QLDStationPickerView: View {
    let title: String
    let selectedStopId: String
    let onSelect: (GTFSStop) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var stations: [GTFSStop] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading && stations.isEmpty {
                ProgressView("Loading stations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Stations", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await performSearch(query: searchText) } }
                }
            } else if stations.isEmpty {
                ContentUnavailableView {
                    Label("No Stations Found", systemImage: "mappin.slash")
                } description: {
                    Text(searchText.isEmpty
                         ? "No Queensland train stations were found."
                         : "No stations match \"\(searchText)\".")
                }
            } else {
                List {
                    ForEach(stations, id: \.stopId) { station in
                        Button {
                            onSelect(station)
                            dismiss()
                        } label: {
                            HStack {
                                Text(station.stopName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if station.stopId == selectedStopId {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.ultraThinMaterial)
                    }
                }
            }
        }
        .navigationTitle("Select \(title)")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search stations"
        )
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(query: newValue)
        }
        .task {
            await performSearch(query: "")
        }
    }

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let results = try await GTFSDatabase.shared.searchTrainStations(query: query)
            guard !Task.isCancelled else { return }
            stations = results
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
