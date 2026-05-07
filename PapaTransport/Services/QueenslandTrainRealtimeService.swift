import Foundation

final class QueenslandTrainRealtimeService {
    static let shared = QueenslandTrainRealtimeService()

    private init() {}

    private let tripUpdatesURL = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates/Rail")!

    func fetchTripUpdates() async -> [String: GTFSRTTripUpdate] {
        do {
            let (data, response) = try await URLSession.shared.data(from: tripUpdatesURL)
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
