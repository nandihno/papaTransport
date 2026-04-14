//
//  TrainSettingsViews.swift
//  myLatest
//
//  Settings drill-down screens for selecting train line, home station,
//  and city station from live Metro Trains Melbourne data.
//
//  Flow:
//    SettingsView
//      ├── NavigationLink → TrainLinePickerView   (website_data.json → line names)
//      ├── NavigationLink → StationPickerView      (op_timetable_{id}.json → unique stations)
//      └── NavigationLink → StationPickerView      (same, for city station)
//

import SwiftUI

// MARK: - Train Line Picker

/// Fetches all Metro Trains lines from website_data.json and lets the user
/// pick one.  Persists both the line name and its numeric ID.
struct TrainLinePickerView: View {
    @Binding var selectedLineName: String
    @AppStorage("trainLineId") private var trainLineId: String = ""

    // Also clear stations when line changes
    @AppStorage("homeStation") private var homeStation: String = ""
    @AppStorage("cityStation") private var cityStation: String = ""

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
        let didChange = selectedLineName != name
        selectedLineName = name
        trainLineId = id

        // Clear stations when line changes — they may no longer be valid.
        if didChange {
            homeStation = ""
            cityStation = ""
        }

        dismiss()
    }
}

// MARK: - Station Picker

/// Fetches the operational timetable for the selected line and presents
/// unique station names for the user to choose from.
struct StationPickerView: View {
    let title: String                   // e.g. "Home Station" or "City Station"
    @Binding var selectedStation: String

    @AppStorage("trainLineId") private var trainLineId: String = ""
    @AppStorage("trainLineName") private var trainLineName: String = ""

    @Environment(\.dismiss) private var dismiss

    @State private var stations: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredStations: [String] {
        if searchText.isEmpty { return stations }
        return stations.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if trainLineId.isEmpty {
                ContentUnavailableView {
                    Label("No Train Line Selected", systemImage: "tram.fill")
                } description: {
                    Text("Please select a train line first, then come back to choose your \(title.lowercased()).")
                }
            } else if isLoading {
                ProgressView("Loading stations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Stations", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") {
                        Task { await fetchStations() }
                    }
                }
            } else if stations.isEmpty {
                ContentUnavailableView {
                    Label("No Stations Found", systemImage: "mappin.slash")
                } description: {
                    Text("No stations were found for the \(trainLineName) line.")
                }
            } else {
                List {
                    ForEach(filteredStations, id: \.self) { station in
                        Button {
                            selectedStation = station
                            dismiss()
                        } label: {
                            HStack {
                                Text(station)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if station == selectedStation {
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
                             prompt: "Search stations")
            }
        }
        .navigationTitle("Select \(title)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !trainLineId.isEmpty else { return }
            await fetchStations()
        }
    }

    // MARK: - Networking

    private func fetchStations() async {
        isLoading = true
        errorMessage = nil

        do {
            let url = URL(string: "https://747813379903-static-assets-production.s3-ap-southeast-2.amazonaws.com/op_timetable_\(trainLineId).json")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let entries = try JSONDecoder().decode([TimetableAPIEntry].self, from: data)

            // Extract unique station names, sorted alphabetically.
            let unique = Set(entries.map(\.station))
                .sorted { $0.localizedCompare($1) == .orderedAscending }

            await MainActor.run {
                stations = unique
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
