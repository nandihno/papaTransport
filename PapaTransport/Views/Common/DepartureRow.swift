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

    @Environment(\.themePalette) private var palette

    init(
        departure: BusDeparture,
        showsRouteBadge: Bool = true,
        isInteractive: Bool = true,
        onTap: @escaping () -> Void = {}
    ) {
        self.departure = departure
        self.showsRouteBadge = showsRouteBadge
        self.isInteractive = isInteractive
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
        .accessibilityHint(isInteractive ? "Shows the stops remaining on this trip." : "")
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            if showsRouteBadge {
                Text(routeBadgeText)
                    .font(.transitLabel.monospacedDigit())
                    .foregroundStyle(palette.buttonForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 40)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(palette.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryTitle)
                    .font(.transitBody)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                detailLine
            }

            Spacer(minLength: 8)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                let duration = departure.minutesAway.durationComponents
                Text(duration.value)
                    .font(.transitDisplay.monospacedDigit())
                    .foregroundStyle(palette.textPrimary)
                if !duration.unit.isEmpty {
                    Text(duration.unit)
                        .font(.transitBadge)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var detailLine: some View {
        HStack(spacing: 4) {
            if let platform = departure.platform, !platform.isEmpty {
                segment("Plat \(platform)", color: palette.textSecondary)
            }

            if departure.expressStopCount > 0 {
                segment("Express", color: palette.accentText)
            }

            // Queensland only — derived from the vehicle's reported position.
            // A stronger signal than the countdown alone: it says the service
            // exists and where it actually is.
            if let stopsAway = departure.stopsAwayDescription {
                segment(stopsAway, color: palette.info)
            }

            segment(timeText, color: hasDelay ? statusColor : palette.textSecondary, isLast: !hasDelay)

            if hasDelay {
                segment(delayText, color: statusColor, isLast: true)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func segment(_ text: String, color: Color, isLast: Bool = false) -> some View {
        Text(text)
            .font(.transitBadge)
            .foregroundStyle(color)
        if !isLast {
            Text("·")
                .font(.transitBadge)
                .foregroundStyle(palette.textTertiary)
        }
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
        parts.append("\(departure.minutesAway) minutes")
        parts.append(departure.status.rawValue)
        if hasDelay { parts.append(delayText) }
        return parts.joined(separator: ", ")
    }
}
