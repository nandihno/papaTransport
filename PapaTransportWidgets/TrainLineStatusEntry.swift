import Foundation
import WidgetKit

struct TrainLineStatusEntry: TimelineEntry, Codable, Hashable {
    let date: Date
    let lineID: String
    let lineName: String
    let serviceIsGood: Bool
    let serviceMessage: String
    let alertCount: Int
    let plannedWorkCount: Int
    let firstPlannedWorkTitle: String?
    let lastUpdatedAt: Date?
    let isStale: Bool
    let isUnavailable: Bool

    static let placeholder = TrainLineStatusEntry(
        date: .now,
        lineID: "",
        lineName: "Select a line",
        serviceIsGood: true,
        serviceMessage: "Choose a train line in the widget settings.",
        alertCount: 0,
        plannedWorkCount: 0,
        firstPlannedWorkTitle: nil,
        lastUpdatedAt: nil,
        isStale: false,
        isUnavailable: false
    )

    static func unavailable(lineID: String, lineName: String) -> TrainLineStatusEntry {
        TrainLineStatusEntry(
            date: .now,
            lineID: lineID,
            lineName: lineName,
            serviceIsGood: false,
            serviceMessage: "Service status is unavailable. Open PapaTransport to try again.",
            alertCount: 0,
            plannedWorkCount: 0,
            firstPlannedWorkTitle: nil,
            lastUpdatedAt: nil,
            isStale: false,
            isUnavailable: true
        )
    }

    func markedStale() -> TrainLineStatusEntry {
        TrainLineStatusEntry(
            date: .now,
            lineID: lineID,
            lineName: lineName,
            serviceIsGood: serviceIsGood,
            serviceMessage: serviceMessage,
            alertCount: alertCount,
            plannedWorkCount: plannedWorkCount,
            firstPlannedWorkTitle: firstPlannedWorkTitle,
            lastUpdatedAt: lastUpdatedAt,
            isStale: true,
            isUnavailable: false
        )
    }

    static func make(lineID: String, info: TrainInfo, fetchedAt: Date = .now) -> TrainLineStatusEntry {
        TrainLineStatusEntry(
            date: fetchedAt,
            lineID: lineID,
            lineName: info.lineName,
            serviceIsGood: info.serviceIsGood,
            serviceMessage: info.serviceStatusMessage,
            alertCount: info.alerts.count,
            plannedWorkCount: info.plannedWorks.count,
            firstPlannedWorkTitle: info.plannedWorks.first?.title,
            lastUpdatedAt: fetchedAt,
            isStale: false,
            isUnavailable: false
        )
    }
}

enum TrainStatusWidgetCache {
    private static let linesKey = "trainStatusWidget.availableLines"

    static func store(lines: [TrainLineDescriptor]) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        UserDefaults.standard.set(data, forKey: linesKey)
    }

    static func loadLines() -> [TrainLineDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: linesKey),
              let lines = try? JSONDecoder().decode([TrainLineDescriptor].self, from: data) else {
            return []
        }
        return lines
    }

    static func store(_ entry: TrainLineStatusEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(for: entry.lineID))
    }

    static func loadEntry(for lineID: String) -> TrainLineStatusEntry? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: lineID)) else { return nil }
        return try? JSONDecoder().decode(TrainLineStatusEntry.self, from: data)
    }

    private static func cacheKey(for lineID: String) -> String {
        "trainStatusWidget.status.\(lineID)"
    }
}
