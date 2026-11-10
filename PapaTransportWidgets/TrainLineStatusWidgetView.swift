import SwiftUI
import WidgetKit

struct TrainLineStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TrainLineStatusEntry

    private var statusColor: Color {
        if entry.isUnavailable { return .secondary }
        if entry.isStale { return .orange }
        return entry.serviceIsGood ? .green : .red
    }

    private var statusTitle: String {
        if entry.isUnavailable { return "Unavailable" }
        if entry.isStale { return "Showing saved status" }
        return entry.serviceIsGood ? "Good service" : "Service alert"
    }

    private var statusSymbol: String {
        if entry.isUnavailable { return "questionmark.circle.fill" }
        if entry.isStale { return "clock.badge.exclamationmark" }
        return entry.serviceIsGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var updateSymbol: String {
        entry.isStale ? "clock.badge.exclamationmark" : "clock"
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(entry.lineName)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            statusBadge

            Text(entry.serviceMessage)
                .font(.caption)
                .foregroundStyle(entry.isUnavailable ? .secondary : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            updateFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header

                Text(entry.lineName)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                statusBadge
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 132, maxHeight: .infinity, alignment: .leading)

            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 104)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Label(entry.alertCount > 0 ? "LATEST ALERT" : "LINE UPDATE",
                      systemImage: entry.alertCount > 0 ? "text.bubble.fill" : "info.circle.fill")
                    .font(.caption2.weight(.bold))
                    .tracking(0.35)
                    .foregroundStyle(entry.alertCount > 0 ? statusColor : .secondary)

                Text(entry.serviceMessage)
                    .font(.subheadline)
                    .foregroundStyle(entry.isUnavailable ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if entry.plannedWorkCount > 0 {
                    plannedWorksBadge
                }

                Spacer(minLength: 0)
                updateFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "tram.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            Text("TRAIN STATUS")
                .font(.caption2.weight(.bold))
                .tracking(0.45)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
    }

    private var statusBadge: some View {
        Label(statusTitle, systemImage: statusSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var plannedWorksBadge: some View {
        Label {
            Text(entry.firstPlannedWorkTitle ?? "\(entry.plannedWorkCount) planned works")
                .lineLimit(1)
        } icon: {
            Image(systemName: "wrench.and.screwdriver.fill")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var updateFooter: some View {
        if let lastUpdatedAt = entry.lastUpdatedAt {
            HStack(spacing: 4) {
                Image(systemName: updateSymbol)
                    .accessibilityHidden(true)
                Text(entry.isStale ? "Saved" : "Updated")
                Text(lastUpdatedAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(entry.isStale ? Color.orange : Color.secondary)
            .lineLimit(1)
        } else {
            Label("No recent data", systemImage: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilitySummary: String {
        var summary = "\(entry.lineName), \(statusTitle). \(entry.serviceMessage)"
        if let lastUpdatedAt = entry.lastUpdatedAt {
            summary += ". Updated \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))."
        }
        if entry.plannedWorkCount > 0 {
            summary += ". \(entry.firstPlannedWorkTitle ?? "\(entry.plannedWorkCount) planned works")"
        }
        return summary
    }
}
