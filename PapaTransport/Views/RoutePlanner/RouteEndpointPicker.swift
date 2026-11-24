import CoreLocation
import MapKit
import SwiftUI

struct RouteEndpoint {
    let mapItem: MKMapItem
    let title: String
    var subtitle: String = ""

    var coordinate: CLLocationCoordinate2D { mapItem.location.coordinate }

    static func pin(at coordinate: CLLocationCoordinate2D, title: String) -> Self {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = title
        return Self(mapItem: item, title: title)
    }
}

struct RouteEndpointPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var isSearchFocused: Bool

    let field: String
    let region: MKCoordinateRegion?
    let onSelect: (RouteEndpoint) -> Void

    @State private var query = ""
    @State private var suggestions = RoutePlaceSuggestions()
    @State private var selection: Selection?
    @State private var activeSearch: MKLocalSearch?
    @State private var errorMessage: String?
    @State private var locationAccessDenied = false

    private enum Selection: Hashable {
        case currentLocation
        case place(MKLocalSearchCompletion)
    }

    private var searchTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Address or place", text: $query)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .accessibilityIdentifier("route.endpoint.query")
                        .disabled(selection != nil)

                    Button("Use Current Location", systemImage: "location.fill") {
                        select(.currentLocation)
                    }
                    .disabled(selection != nil)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                        if locationAccessDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        }
                    }
                }

                if let selection {
                    switch selection {
                    case .currentLocation:
                        ProgressView("Finding your location…")
                    case .place:
                        ProgressView("Finding this place…")
                    }
                } else if searchTerm.count >= 2 {
                    Section("Suggestions") {
                        suggestionRows
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(field)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: searchTerm) {
                errorMessage = nil
                locationAccessDenied = false
                await suggestions.update(for: searchTerm, region: region)
            }
            .task(id: selection) {
                guard let selection else { return }
                await resolve(selection)
            }
            .onDisappear {
                suggestions.cancel()
                activeSearch?.cancel()
            }
        }
    }

    @ViewBuilder
    private var suggestionRows: some View {
        if suggestions.query != searchTerm || suggestions.isLoading {
            ProgressView("Searching…")
        } else if suggestions.failed {
            Text("Search is unavailable. Edit your search or try again.")
                .foregroundStyle(.secondary)
            Button("Try Again") {
                suggestions.start(for: searchTerm, region: region)
            }
        } else if suggestions.results.isEmpty {
            Text("No matches. Try adding a suburb or city.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(suggestions.results, id: \.self) { completion in
                Button {
                    select(.place(completion))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(completion.title)
                            .foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func select(_ choice: Selection) {
        isSearchFocused = false
        errorMessage = nil
        locationAccessDenied = false
        selection = choice
    }

    private func resolve(_ selection: Selection) async {
        defer {
            activeSearch = nil
            self.selection = nil
        }
        do {
            let endpoint: RouteEndpoint
            switch selection {
            case .currentLocation:
                let location = try await LocationManager().currentLocation()
                endpoint = .pin(at: location.coordinate, title: "Current Location")
            case .place(let completion):
                let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
                activeSearch = search
                let response = try await search.start()
                try Task.checkCancellation()
                guard let item = response.mapItems.first(where: {
                    CLLocationCoordinate2DIsValid($0.location.coordinate)
                }) else {
                    errorMessage = "This place couldn’t be located. Try another suggestion."
                    return
                }
                endpoint = RouteEndpoint(mapItem: item, title: completion.title, subtitle: completion.subtitle)
            }
            try Task.checkCancellation()
            onSelect(endpoint)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            switch selection {
            case .currentLocation:
                locationAccessDenied = (error as? LocationError) == .denied
                errorMessage = locationAccessDenied
                    ? "Allow location access in Settings to use your current location."
                    : "Couldn’t get your current location. Try again or search for a place."
            case .place:
                errorMessage = "Couldn’t load this place. Try again or choose another suggestion."
            }
        }
    }
}

@Observable
private final class RoutePlaceSuggestions: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var query = ""
    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var isLoading = false
    private(set) var failed = false

    @ObservationIgnored private var completer: MKLocalSearchCompleter?

    func update(for query: String, region: MKCoordinateRegion?) async {
        cancel()
        results = []
        failed = false
        isLoading = query.count >= 2
        self.query = query
        guard isLoading else { return }

        do {
            try await Task.sleep(for: .milliseconds(300))
            start(for: query, region: region)
        } catch {
            // A new query or dismissal cancelled the debounce.
        }
    }

    func start(for query: String, region: MKCoordinateRegion?) {
        guard query == self.query else { return }
        cancel()
        isLoading = true
        failed = false

        let completer = MKLocalSearchCompleter()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let region {
            completer.region = region
        }
        self.completer = completer
        completer.queryFragment = query
    }

    func cancel() {
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer else { return }
        results = completer.results
        isLoading = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer else { return }
        results = []
        isLoading = false
        failed = true
    }
}
