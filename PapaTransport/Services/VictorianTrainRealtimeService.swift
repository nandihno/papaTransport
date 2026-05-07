import Foundation

final class VictorianTrainRealtimeService {
    static let shared = VictorianTrainRealtimeService()

    private init() {}

    private let tripUpdatesURL = URL(string: "https://api.opendata.transport.vic.gov.au/opendata/public-transport/gtfs/realtime/v1/train/trip-updates")!

    func fetchTripUpdates() async -> [String: GTFSRTTripUpdate] {
        let apiKey = APIKeys.victorianBusRealtime
            ?? UserDefaults.standard.string(forKey: VictorianBusService.realtimeAPIKeyDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        guard !apiKey.isEmpty else { return [:] }

        var components = URLComponents(url: tripUpdatesURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "subscription-key", value: apiKey))
        components?.queryItems = queryItems

        guard let requestURL = components?.url else { return [:] }

        var request = URLRequest(url: requestURL)
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(apiKey, forHTTPHeaderField: "KeyID")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                return [:]
            }

            let feed = try GTFSRTFeedMessage(data: data)
            var byTripId: [String: GTFSRTTripUpdate] = [:]
            for entity in feed.entities {
                if let tripUpdate = entity.tripUpdate, !tripUpdate.tripId.isEmpty {
                    byTripId[tripUpdate.tripId] = tripUpdate
                }
            }
            return byTripId
        } catch {
            return [:]
        }
    }
}
