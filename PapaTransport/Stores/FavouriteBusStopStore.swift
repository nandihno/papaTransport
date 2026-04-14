//
//  FavouriteBusStopStore.swift
//  myLatest
//
//  Persists user's favourite bus stops so they always appear
//  in the bus departure card regardless of proximity.
//

import Combine
import Foundation

struct FavouriteBusStop: Codable, Identifiable {
    let provider: BusProvider
    let stopId: String
    let stopName: String
    let stopCode: String?
    let latitude: Double
    let longitude: Double

    var id: String { "\(provider.rawValue):\(stopId)" }

    init(provider: BusProvider = .queenslandTransLink,
         stopId: String,
         stopName: String,
         stopCode: String?,
         latitude: Double,
         longitude: Double) {
        self.provider = provider
        self.stopId = stopId
        self.stopName = stopName
        self.stopCode = stopCode
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case stopId
        case stopName
        case stopCode
        case latitude
        case longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(BusProvider.self, forKey: .provider) ?? .queenslandTransLink
        stopId = try container.decode(String.self, forKey: .stopId)
        stopName = try container.decode(String.self, forKey: .stopName)
        stopCode = try container.decodeIfPresent(String.self, forKey: .stopCode)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
    }
}

final class FavouriteBusStopStore: ObservableObject {
    static let shared = FavouriteBusStopStore()

    @Published private(set) var all: [FavouriteBusStop] = []

    private let storageKey = "PapaTransport.favouriteBusStops"

    private init() {
        load()
    }

    func add(_ stop: FavouriteBusStop) {
        guard !all.contains(where: { $0.stopId == stop.stopId && $0.provider == stop.provider }) else { return }
        all.append(stop)
        persist()
    }

    func remove(stopId: String, provider: BusProvider = .queenslandTransLink) {
        all.removeAll { $0.stopId == stopId && $0.provider == provider }
        persist()
    }

    func delete(offsets: IndexSet, provider: BusProvider = .queenslandTransLink) {
        let filtered = all.filter { $0.provider == provider }
        let idsToDelete = Set(offsets.compactMap { filtered.indices.contains($0) ? filtered[$0].id : nil })
        all.removeAll { idsToDelete.contains($0.id) }
        persist()
    }

    func favourites(for provider: BusProvider) -> [FavouriteBusStop] {
        all.filter { $0.provider == provider }
    }

    func count(for provider: BusProvider) -> Int {
        favourites(for: provider).count
    }

    func contains(stopId: String, provider: BusProvider = .queenslandTransLink) -> Bool {
        all.contains { $0.stopId == stopId && $0.provider == provider }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let stops = try? JSONDecoder().decode([FavouriteBusStop].self, from: data)
        else { return }
        all = stops
    }
}
