import SwiftUI

/// Shared departure row for train, bus and tram boards.
///
/// Replaces three near-identical renderings (`TrainDepartureRow`, the inline
/// row in the former per-line grouping, and `BusDepartureRow`). Each fact is
/// stated once — status is a colour, not repeated as text three times — see
/// UIRevampPlan.md Phase 2 §2.3.
struct DepartureRow: View {
    let departure: BusDeparture
    let showsRouteBadge: Bool
    let isInteractive: Bool
    let onTap: () -> Void
    var isSelected: Bool = false
    var highlightsRoute: Bool = false

    @Environment(\.themePalette) private var palette

    init(
        departure: BusDeparture,
        showsRouteBadge: Bool = true,
        isInteractive: Bool = true,
        isSelected: Bool = false,
        highlightsRoute: Bool = false,
        onTap: @escaping () -> Void = {}
    ) {
        self.departure = departure
        self.showsRouteBadge = showsRouteBadge
        self.isInteractive = isInteractive
        self.isSelected = isSelected
        self.highlightsRoute = highlightsRoute
        self.onTap = onTap
    }

    var body: some View {
        Group {
            if isInteractive {
                Button(action: onTap) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isInteractive ? (highlightsRoute ? "Shows trip details and highlights this service on the map." : "Shows the stops remaining on this trip.") : "")
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryTitle)
                    .font(.transitBody)
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsRouteBadge {
                        Text(routeBadgeText)
                            .font(.transitBadge.monospacedDigit())
                            .foregroundStyle(palette.buttonForeground)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(palette.buttonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    detailLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                let duration = departure.minutesAway.durationComponents
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

            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .background(isSelected ? palette.info.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private var detailLine: some View {
        var segments: [(String, Color)] = []
        if let platform = departure.platform, !platform.isEmpty {
            segments.append(("Plat \(platform)", palette.textSecondary))
        }
        if departure.expressStopCount > 0 {
            segments.append(("Express", palette.accentText))
        }
        if let stopsAway = departure.stopsAwayDescription {
            segments.append((stopsAway, palette.info))
        }
        segments.append((timeText, hasDelay ? statusColor : palette.textSecondary))
        if hasDelay {
            segments.append((delayText, statusColor))
        }
        let text = segments.enumerated().reduce(Text("")) { result, item in
            let separator = item.offset == 0 ? Text("") : Text(" · ").foregroundColor(palette.textTertiary)
            let segment = Text(item.element.0).foregroundColor(item.element.1)
            return Text("\(result)\(separator)\(segment)")
        }
        return text
            .font(.transitBadge)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Late/early only — `onTime` can still carry a few seconds of
    /// `delaySeconds` and printing that as text would be noise, not signal.
    private var hasDelay: Bool {
        departure.status == .late || departure.status == .early
    }

    /// Both times are shown in full ("3:30 pm → 3:31 pm") rather than
    /// stripping the meridiem marker from the first — the source strings are
    /// locale-formatted and not safe to slice.
    private var timeText: String {
        guard hasDelay, let predicted = departure.predictedTime else {
            return departure.scheduledTime
        }
        return "\(departure.scheduledTime) → \(predicted)"
    }

    private var delayText: String {
        let minutes = max(1, abs(departure.delaySeconds) / 60)
        return departure.delaySeconds > 0 ? "\(minutes) min late" : "\(minutes) min early"
    }

    private var routeBadgeText: String {
        let value = departure.routeShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "•" : value
    }

    private var primaryTitle: String {
        let value = (departure.headsign ?? departure.routeLongName).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Service details unavailable" : value
    }

    private var statusColor: Color {
        palette.color(for: departure.status)
    }

    private var accessibilityLabel: String {
        var parts = [primaryTitle]
        if showsRouteBadge { parts.append("Route \(routeBadgeText)") }
        if let platform = departure.platform, !platform.isEmpty { parts.append("Platform \(platform)") }
        if departure.expressStopCount > 0 { parts.append("Express") }
        if let stopsAway = departure.stopsAwayDescription { parts.append(stopsAway) }
        parts.append("Scheduled \(departure.scheduledTime)")
        if let predicted = departure.predictedTime, hasDelay { parts.append("Expected \(predicted)") }
        parts.append("\(departure.minutesAway) minutes")
        parts.append(departure.status.rawValue)
        if hasDelay { parts.append(delayText) }
        return parts.joined(separator: ", ")
    }
}
