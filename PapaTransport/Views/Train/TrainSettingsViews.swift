//
//  TrainSettingsViews.swift
//  myLatest
//
//  Settings drill-down for choosing the Victorian train line, from live Metro
//  Trains Melbourne data (website_data.json → line names).
//
//  The line drives status, alerts and planned works. It does not drive
//  departures — those come from the stations visible on the map, via the PTV
//  API. The home/city station pickers that used to live here were removed with
//  the departure list they fed; see UIRevampPlan.md.
//

import SwiftUI

// MARK: - Train Line Picker

/// Fetches all Metro Trains lines from website_data.json and lets the user
/// pick one.  Persists both the line name and its numeric ID.
struct TrainLinePickerView: View {
    @Binding var selectedLineName: String
    @AppStorage("trainLineId") private var trainLineId: String = ""

    @Environment(\.dismiss) private var dismiss

    @State private var lines: [(id: String, name: String)] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredLines: [(id: String, name: String)] {
        if searchText.isEmpty { return lines }
        return lines.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading train lines…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Lines", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") {
                        Task { await fetchLines() }
                    }
                }
            } else {
                List {
                    ForEach(filteredLines, id: \.id) { line in
                        Button {
                            selectLine(id: line.id, name: line.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                }

                                Spacer()

                                if line.name == selectedLineName {
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
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                             prompt: "Search lines")
            }
        }
        .navigationTitle("Select Train Line")
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetchLines() }
    }

    // MARK: - Networking

    private func fetchLines() async {
        isLoading = true
        errorMessage = nil

        do {
            let url = URL(string: "https://747813379903-static-assets-production.s3-ap-southeast-2.amazonaws.com/website_data.json")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(WebsiteDataResponse.self, from: data)

            let parsed = response.lines
                .filter { !$0.data.lineName.isEmpty }
                .map { (id: $0.lineId, name: $0.data.lineName) }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

            await MainActor.run {
                lines = parsed
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Selection

    private func selectLine(id: String, name: String) {
        selectedLineName = name
        trainLineId = id
        dismiss()
    }
}
