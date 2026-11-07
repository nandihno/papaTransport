import SwiftUI

/// Expandable section for one direction's departures — "City", "Werribee",
/// or a bus/tram destination. Replaces the old per-line grouping; see
/// UIRevampPlan.md Phase 2 §2.2.
struct DepartureGroupSection: View {
    let group: DepartureDirectionGroup
    let isExpanded: Bool
    var selectedDeparture: MapDepartureSelection? = nil
    var stopId: String = ""
    let onToggleExpanded: () -> Void
    let onSelectDeparture: (BusDeparture) -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 12) {
                    Image(systemName: group.isCityward ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(group.isCityward ? palette.info : palette.accentText)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.label)
                            .font(.transitBody)
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)

                        Text(group.secondarySummary)
                            .font(.transitCaption)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if let next = group.nextDeparture {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            let duration = next.minutesAway.durationComponents
                            Text(duration.value)
                                .font(.transitDisplay.monospacedDigit())
                                .foregroundStyle(palette.textPrimary)
                            if !duration.unit.isEmpty {
                                Text(duration.unit)
                                    .font(.transitBadge)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(group.departures) { departure in
                        DepartureRow(
                            departure: departure,
                            isSelected: selectedDeparture?.matches(departure, at: stopId) == true,
                            highlightsRoute: true
                        ) {
                            onSelectDeparture(departure)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .onChange(of: containsSelectedDeparture, initial: true) { _, selected in
            if selected, !isExpanded {
                onToggleExpanded()
            }
        }
    }

    private var containsSelectedDeparture: Bool {
        group.departures.contains { selectedDeparture?.matches($0, at: stopId) == true }
    }
}

private extension DepartureDirectionGroup {
    var secondarySummary: String {
        guard let next = nextDeparture else { return "No scheduled services" }
        let firstTime = "Next \(next.scheduledTime)"
        return departures.count == 1
            ? "\(firstTime) • 1 service"
            : "\(firstTime) • \(departures.count) services"
    }
}
