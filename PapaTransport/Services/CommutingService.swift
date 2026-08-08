import CoreLocation
import Foundation

final class CommutingService {
    static let shared = CommutingService()

    private init() {}

    func fetchSnapshot(
        trainLineName: String,
        transportRegion: TransportRegion,
        includeTrain: Bool,
        includeBus: Bool
    ) async -> CommutingSnapshot {
        async let trainTask: TrainInfo? = {
            guard includeTrain, transportRegion == .victorian else { return nil }
            return await fetchTrainInfo(lineName: trainLineName)
        }()

        async let busTask: BusInfo? = {
            guard includeBus else { return nil }
            return await fetchBusInfo(for: transportRegion)
        }()

        return await CommutingSnapshot(
            trainInfo: trainTask,
            busInfo: busTask,
            fetchedAt: Date()
        )
    }

    private func fetchTrainInfo(lineName: String) async -> TrainInfo {
        guard !lineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .placeholder(lineName: lineName)
        }

        do {
            return try await TrainService.shared.fetchTrainInfo(lineName: lineName)
        } catch {
            print("⚠️ TrainService failed (\(error.localizedDescription)); using placeholder train data.")
            return .placeholder(lineName: lineName)
        }
    }

    private func fetchBusInfo(for region: TransportRegion) async -> BusInfo {
        let provider: any BusDataProviding = switch region {
        case .queensland:
            BusService.shared
        case .victorian:
            PTVBoardService.victorianBus
        }

        do {
            let location = try await LocationManager().currentLocation()
            return try await provider.fetchBusInfo(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        } catch {
            if error is LocationError {
                return BusInfo.noLocation(provider: provider.provider)
            }

            print("⚠️ Bus service failed (\(error.localizedDescription)); returning empty board.")
            return BusInfo(
                provider: provider.provider,
                nearbyStops: [],
                favouriteStops: [],
                alerts: [],
                localTimeAtFetch: "--:-- --",
                locationAvailable: true
            )
        }
    }
}
