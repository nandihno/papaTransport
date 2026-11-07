import SwiftUI

struct MapPeekDeparture {
    let departure: BusDeparture
    let stopName: String
    let onSelect: () -> Void
}

struct MapPeekDepartureRow: View {
    let item: MapPeekDeparture
    let onShowDepartures: () -> Void

    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            onShowDepartures()
            item.onSelect()
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        serviceDescription
                        countdown
                    }
                } else {
                    HStack(spacing: 12) {
                        serviceDescription
                        Spacer(minLength: 0)
                        countdown
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the departure list and highlights this route on the map.")
    }

    private var serviceDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Next · \(item.stopName)")
                .font(.transitCaption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)

            Text(destination)
                .font(.transitBody)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)

            Text("\(item.departure.predictedTime ?? item.departure.scheduledTime) · \(item.departure.status.rawValue)")
                .font(.transitCaption)
                .foregroundStyle(palette.color(for: item.departure.status))
                .lineLimit(2)
        }
    }

    private var countdown: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            let duration = item.departure.minutesAway.durationComponents
            Text(duration.value)
                .font(.transitTitle.monospacedDigit())
                .foregroundStyle(palette.textPrimary)
            if !duration.unit.isEmpty {
                Text(duration.unit)
                    .font(.transitBadge)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .fixedSize()
    }

    private var destination: String {
        let departure = item.departure
        let route = departure.routeShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        let headsign = (departure.headsign ?? departure.routeLongName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = headsign.isEmpty ? "Service details unavailable" : headsign
        return route.isEmpty || route == title ? title : "\(route) · \(title)"
    }

    private var accessibilityLabel: String {
        "Next departure from \(item.stopName), \(destination), \(item.departure.minutesAway) minutes, \(item.departure.status.rawValue)"
    }
}
