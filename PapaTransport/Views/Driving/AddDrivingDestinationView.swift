//
//  AddDrivingDestinationView.swift
//  PapaTransport
//

import Combine
import Foundation
import MapKit
import SwiftUI

// MARK: - Add Destination

struct AddDrivingDestinationView: View {
    @Environment(DrivingDestinationStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searchModel = DestinationSearchModel()
    @State private var customTitle = ""
    @State private var setArrivalTime = false
    @State private var arrivalTime = Date()

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                if searchModel.selectedDestination != nil {
                    titleSection
                    arrivalTimeSection
                    selectedSection
                }
                suggestionsSection
            }
            .navigationTitle("Add Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(searchModel.selectedDestination == nil)
                }
            }
        }
    }

    // MARK: - Sections

    private var searchSection: some View {
        Section {
            TextField("Start typing an address", text: $searchModel.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()

            if searchModel.isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching Apple Maps…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = searchModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Destination Search")
        } footer: {
            Text("Choose a suggestion to lock in the exact location.")
        }
    }

    private var titleSection: some View {
        Section {
            TextField("e.g. Home, Work, Gym", text: $customTitle)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Label (Optional)")
        } footer: {
            Text("Give this destination a friendly name. If empty, the address is used instead.")
        }
    }

    private var arrivalTimeSection: some View {
        Section {
            Toggle("Set arrival time target", isOn: $setArrivalTime)
            if setArrivalTime {
                DatePicker(
                    "Arrive by",
                    selection: $arrivalTime,
                    displayedComponents: .hourAndMinute
                )
            }
        } header: {
            Text("Arrival Time (Optional)")
        } footer: {
            if setArrivalTime {
                Text("The app will calculate when you need to leave to arrive on time, and show a live countdown.")
            } else {
                Text("Set a daily arrival target to see a \"Leave in X min\" countdown next to this destination.")
            }
        }
    }

    private var selectedSection: some View {
        Section {
            if let dest = searchModel.selectedDestination {
                DestinationPreviewRow(destination: dest.withTitle(customTitle))
            }
        } header: {
            Text("Selected Destination")
        }
    }

    private var suggestionsSection: some View {
        Section {
            if searchModel.suggestions.isEmpty {
                Text(searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3
                     ? "Enter at least 3 characters to see suggestions."
                     : "No matching addresses found yet.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(searchModel.suggestions) { suggestion in
                    Button {
                        searchModel.select(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.title).foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Suggestions")
        }
    }

    // MARK: - Save

    private func save() {
        guard var destination = searchModel.selectedDestination else { return }
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        destination.title = trimmed.isEmpty ? nil : trimmed
        if setArrivalTime {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: arrivalTime)
            destination.targetArrivalHour = comps.hour
            destination.targetArrivalMinute = comps.minute
        }
        store.add(destination)
        dismiss()
    }
}

// MARK: - Edit Destination

struct EditDrivingDestinationView: View {
    @Environment(DrivingDestinationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let destination: DrivingDestination
    @State private var editedTitle: String
    @State private var setArrivalTime: Bool
    @State private var arrivalTime: Date
    @State private var showAddressSearch = false
    @StateObject private var searchModel = DestinationSearchModel()

    init(destination: DrivingDestination) {
        self.destination = destination
        _editedTitle = State(initialValue: destination.title ?? "")
        let hasTarget = destination.targetArrivalHour != nil
        _setArrivalTime = State(initialValue: hasTarget)
        if let hour = destination.targetArrivalHour, let minute = destination.targetArrivalMinute {
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let date = Calendar.current.date(from: comps) ?? Date()
            _arrivalTime = State(initialValue: date)
        } else {
            _arrivalTime = State(initialValue: Date())
        }
    }

    private var resolvedDestination: DrivingDestination {
        let base = searchModel.selectedDestination ?? destination
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var hour: Int? = nil
        var minute: Int? = nil
        if setArrivalTime {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: arrivalTime)
            hour = comps.hour
            minute = comps.minute
        }
        return DrivingDestination(
            id: destination.id,
            name: base.name,
            address: base.address,
            latitude: base.latitude,
            longitude: base.longitude,
            title: trimmed.isEmpty ? nil : trimmed,
            targetArrivalHour: hour,
            targetArrivalMinute: minute
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Home, Work, Gym", text: $editedTitle)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Label (Optional)")
                }

                Section {
                    Toggle("Set arrival time target", isOn: $setArrivalTime)
                    if setArrivalTime {
                        DatePicker("Arrive by", selection: $arrivalTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Arrival Time")
                } footer: {
                    Text("Shows a \"Leave in X min\" countdown on the Driving tab.")
                }

                Section {
                    DestinationPreviewRow(destination: resolvedDestination)
                } header: {
                    Text("Preview")
                }

                Section {
                    if !showAddressSearch {
                        Button("Change Address") { showAddressSearch = true }
                    } else {
                        TextField("Start typing a new address", text: $searchModel.query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()

                        if searchModel.isSearching {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching Apple Maps…").foregroundStyle(.secondary)
                            }
                        }

                        if let errorMessage = searchModel.errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }

                        if searchModel.selectedDestination != nil {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("New address selected").font(.subheadline)
                            }
                        }
                    }
                } header: {
                    Text("Address")
                } footer: {
                    if !showAddressSearch { Text(destination.address) }
                }

                if showAddressSearch && !searchModel.suggestions.isEmpty {
                    Section {
                        ForEach(searchModel.suggestions) { suggestion in
                            Button {
                                searchModel.select(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(suggestion.title).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Suggestions")
                    }
                }
            }
            .navigationTitle("Edit Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.update(resolvedDestination)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Destination Preview Row

struct DestinationPreviewRow: View {
    let destination: DrivingDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(destination.displayName).font(.body)
            Text(destination.displaySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let arrivalDisplay = destination.arrivalTargetDisplay {
                Text(arrivalDisplay)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - DestinationSearchModel

@MainActor
final class DestinationSearchModel: NSObject, ObservableObject {
    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion
    }

    @Published var query = "" {
        didSet { handleQueryChange() }
    }
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var selectedDestination: DrivingDestination?
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    private var suppressQuerySideEffects = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func select(_ suggestion: Suggestion) {
        Task { await resolve(suggestion) }
    }

    private func handleQueryChange() {
        guard !suppressQuerySideEffects else { return }

        selectedDestination = nil
        errorMessage = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            suggestions = []
            isSearching = false
            completer.queryFragment = ""
            return
        }

        isSearching = true
        completer.queryFragment = trimmed
    }

    private func resolve(_ suggestion: Suggestion) async {
        isSearching = true
        errorMessage = nil

        do {
            let request = MKLocalSearch.Request(completion: suggestion.completion)
            request.resultTypes = .address

            let response = try await Self.startSearch(request)
            guard let item = response.mapItems.first else {
                errorMessage = "The selected address could not be resolved."
                isSearching = false
                return
            }

            let location = item.location
            let resolved = DrivingDestination(
                name: item.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? suggestion.title,
                address: Self.formattedAddress(for: item, fallbackSubtitle: suggestion.subtitle),
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )

            suppressQuerySideEffects = true
            query = resolved.address
            suppressQuerySideEffects = false

            selectedDestination = resolved
            suggestions = []
            isSearching = false
        } catch is CancellationError {
            errorMessage = "Address search was cancelled."
            isSearching = false
        } catch {
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }

    private static func startSearch(_ request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        let search = MKLocalSearch(request: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                search.start { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: LocationError.unavailable)
                    }
                }
            }
        } onCancel: {
            search.cancel()
        }
    }

    private static func formattedAddress(for item: MKMapItem, fallbackSubtitle: String) -> String {
        // Try the full formatted address from addressRepresentations first (most complete)
        if let formatted = item.addressRepresentations?
            .fullAddress(includingRegion: true, singleLine: true),
           !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return formatted
        }

        // Fall back to MKAddress.fullAddress
        if let full = item.address?.fullAddress as String?,
           !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return full
        }

        // Fall back to the item name or the completer subtitle
        if let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return name
        }

        return fallbackSubtitle.isEmpty ? "Selected destination" : fallbackSubtitle
    }
}

extension DestinationSearchModel: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results.map {
            Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        isSearching = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
        errorMessage = error.localizedDescription
        isSearching = false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
