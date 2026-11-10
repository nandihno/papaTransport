import SwiftUI
import WidgetKit

@main
struct PapaTransportWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrainLineStatusWidget()
    }
}

struct TrainLineStatusWidget: Widget {
    private let kind = "TrainLineStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: TrainLineStatusConfiguration.self,
            provider: TrainLineStatusProvider()
        ) { entry in
            TrainLineStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Train Line Status")
        .description("Check the service status and current alerts for a train line.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
