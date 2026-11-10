import AppIntents
import Foundation

struct TrainLineEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Train Line")
    static let defaultQuery = TrainLineEntityQuery()

    let id: String
    @Property(title: "Name") var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct TrainLineEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TrainLineEntity] {
        let lines = await availableLines()
        return lines.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TrainLineEntity] {
        await availableLines()
    }

    func defaultResult() async -> TrainLineEntity? {
        await availableLines().first
    }

    private func availableLines() async -> [TrainLineEntity] {
        do {
            let lines = try await TrainService.shared.fetchTrainLines()
            await MainActor.run {
                TrainStatusWidgetCache.store(lines: lines)
            }
            return lines.map { TrainLineEntity(id: $0.id, name: $0.name) }
        } catch {
            let cachedLines = await MainActor.run {
                TrainStatusWidgetCache.loadLines()
            }
            return cachedLines.map {
                TrainLineEntity(id: $0.id, name: $0.name)
            }
        }
    }
}

struct TrainLineStatusConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Train Line Status"
    static var description = IntentDescription("Choose the Melbourne train line to monitor.")

    @Parameter(title: "Train Line") var trainLine: TrainLineEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$trainLine) status")
    }

    init() {
        trainLine = nil
    }

    init(trainLine: TrainLineEntity?) {
        self.trainLine = trainLine
    }
}
