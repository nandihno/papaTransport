import SwiftUI

/// One stop in a trip's remaining-stops timeline. Shared by the bus, tram and
/// train trip-detail sheets — all three render the same shape.
struct TripStopRow: View {
    let stop: BusTripStopDetail
    let isLast: Bool

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(markerColor)
                    .frame(width: stop.isSelectedStop ? 12 : 9, height: stop.isSelectedStop ? 12 : 9)
                    .padding(.top, 4)

                if !isLast {
                    Rectangle()
                        .fill(palette.textTertiary.opacity(0.35))
                        .frame(width: 2, height: 28)
                        .padding(.top, 4)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stop.stopName)
                        .font(.transitBody)
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if stop.isSelectedStop {
                        Text("Selected")
                            .font(.transitBadge)
                            .foregroundStyle(palette.buttonForeground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(palette.buttonBackground, in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    if let stopCode = stop.stopCode, !stopCode.isEmpty {
                        Text("Stop #\(stopCode)")
                            .font(.transitCaption)
                            .foregroundStyle(palette.textSecondary)
                    }

                    if let scheduledTime = stop.scheduledTime {
                        Text(scheduledTime)
                            .font(.transitLabel)
                            .foregroundStyle(stop.isSelectedStop ? palette.accentText : palette.textSecondary)
                    }

                    if let predictedTime = stop.predictedTime {
                        Text("Pred \(predictedTime)")
                            .font(.transitLabel)
                            .foregroundStyle(statusColor)
                    }

                    if let status = stop.status {
                        Text(status.rawValue)
                            .font(.transitBadge)
                            .foregroundStyle(statusColor)
                    }

                    if let delaySeconds = stop.delaySeconds,
                       let status = stop.status,
                       status != .noData,
                       status != .skipped,
                       delaySeconds != 0 {
                        let delayText = delaySeconds > 0 ? "+\(delaySeconds)s" : "\(delaySeconds)s"
                        Text(delayText)
                            .font(.transitBadge)
                            .foregroundStyle(statusColor)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var markerColor: Color {
        if stop.isSelectedStop {
            return palette.accent
        }
        if let status = stop.status {
            return palette.color(for: status)
        }
        return palette.textTertiary.opacity(0.75)
    }

    private var statusColor: Color {
        guard let status = stop.status else { return palette.textSecondary }
        return palette.color(for: status)
    }
}
