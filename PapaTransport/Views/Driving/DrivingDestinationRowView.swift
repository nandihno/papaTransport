//
//  DrivingDestinationRowView.swift
//  PapaTransport
//

import SwiftUI

struct DrivingDestinationRowView: View {
    let estimate: DrivingTimeEstimate
    let provider: DrivingProvider
    /// Current time, refreshed externally so the countdown stays live without re-fetching Maps.
    var now: Date = Date()

    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette

    private var travelColor: Color {
        estimate.hasDelay ? AppTheme.danger : AppTheme.success
    }

    private var statusText: String {
        if let delayMinutes = estimate.delayMinutes, delayMinutes > 0 {
            return "+\(delayMinutes) min delay"
        }
        if estimate.hasDelay {
            return estimate.advisory ?? "Traffic delay reported"
        }
        return "No reported delay"
    }

    private func openInMaps() {
        let dest = estimate.destination
        switch provider {
        case .apple:
            if let url = URL(string: "http://maps.apple.com/?daddr=\(dest.latitude),\(dest.longitude)&dirflg=d") {
                openURL(url)
            }
        case .google:
            let appURL = URL(string: "comgooglemaps://?daddr=\(dest.latitude),\(dest.longitude)&directionsmode=driving")!
            let webURL = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(dest.latitude),\(dest.longitude)&travelmode=driving")!
            openURL(appURL) { accepted in
                if !accepted { openURL(webURL) }
            }
        }
    }

    var body: some View {
        Button(action: openInMaps) {
            HStack(alignment: .top, spacing: 12) {
                // Left: name + address + countdown
                VStack(alignment: .leading, spacing: 4) {
                    Text(estimate.destination.displayName)
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    Text(estimate.destination.displaySubtitle)
                        .font(.transit(13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let arrivalDisplay = estimate.destination.arrivalTargetDisplay {
                        Text(arrivalDisplay)
                            .font(.transit(12, weight: .medium))
                            .foregroundStyle(palette.textTertiary)
                    }

                    if let countdown = estimate.countdownText(now: now) {
                        countdownPill(text: countdown, urgency: estimate.countdownUrgency)
                    }
                }

                Spacer(minLength: 12)

                // Right: travel time or error
                if let errorMessage = estimate.errorMessage {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Unavailable")
                            .font(.transit(18, weight: .bold))
                            .foregroundStyle(AppTheme.danger)
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else if let travelMinutes = estimate.travelMinutes {
                    VStack(alignment: .trailing, spacing: 4) {
                        travelTimeDisplay(minutes: travelMinutes)
                        Text(statusText)
                            .font(.transit(12, weight: .bold))
                            .foregroundStyle(travelColor)
                            .multilineTextAlignment(.trailing)
                        if let advisory = estimate.advisory {
                            Text(advisory)
                                .font(.transit(12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func travelTimeDisplay(minutes: Int) -> some View {
        let (value, unit) = minutes.durationComponents
        if unit.isEmpty {
            Text(value)
                .font(.transit(28, weight: .heavy))
                .foregroundStyle(travelColor)
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.transit(28, weight: .heavy))
                    .foregroundStyle(travelColor)
                Text(unit)
                    .font(.transit(14, weight: .bold))
                    .foregroundStyle(travelColor)
            }
        }
    }

    private func countdownPill(text: String, urgency: CountdownUrgency) -> some View {
        let color: Color = {
            switch urgency {
            case .none:        return palette.textTertiary
            case .comfortable: return AppTheme.success
            case .soon:        return AppTheme.warning
            case .urgent:      return AppTheme.danger
            }
        }()

        return Text(text)
            .font(.transit(11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
