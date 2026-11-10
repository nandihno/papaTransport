import Foundation
import WidgetKit

struct TrainLineStatusProvider: AppIntentTimelineProvider {
    typealias Entry = TrainLineStatusEntry
    typealias Intent = TrainLineStatusConfiguration

    func placeholder(in context: Context) -> TrainLineStatusEntry {
        .placeholder
    }

    func snapshot(for configuration: TrainLineStatusConfiguration, in context: Context) async -> TrainLineStatusEntry {
        guard let trainLine = configuration.trainLine else { return .placeholder }
        if context.isPreview {
            return TrainLineStatusEntry(
                date: .now,
                lineID: trainLine.id,
                lineName: trainLine.name,
                serviceIsGood: false,
                serviceMessage: "Minor delays through the city loop.",
                alertCount: 1,
                plannedWorkCount: 2,
                firstPlannedWorkTitle: "Weekend track works",
                lastUpdatedAt: .now,
                isStale: false,
                isUnavailable: false
            )
        }
        return await loadEntry(for: trainLine)
    }

    func timeline(for configuration: TrainLineStatusConfiguration, in context: Context) async -> Timeline<TrainLineStatusEntry> {
        let entry: TrainLineStatusEntry
        if let trainLine = configuration.trainLine {
            entry = await loadEntry(for: trainLine)
        } else {
            entry = .placeholder
        }

        return Timeline(
            entries: [entry],
            policy: .after(.now.addingTimeInterval(30 * 60))
        )
    }

    private func loadEntry(for trainLine: TrainLineEntity) async -> TrainLineStatusEntry {
        do {
            let info = try await TrainService.shared.fetchTrainInfo(lineName: trainLine.name)
            let entry = TrainLineStatusEntry.make(lineID: trainLine.id, info: info)
            TrainStatusWidgetCache.store(entry)
            return entry
        } catch {
            return TrainStatusWidgetCache.loadEntry(for: trainLine.id)?.markedStale()
                ?? .unavailable(lineID: trainLine.id, lineName: trainLine.name)
        }
    }
}
