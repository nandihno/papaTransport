import SwiftUI
import WidgetKit

struct TrainLineStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    let entry: TrainLineStatusEntry

    // MARK: - Semantic Colors & Theme

    private var statusColor: Color {
        if entry.isUnavailable { return .secondary }
        if entry.isStale {
            return colorScheme == .dark
                ? Color(red: 1.00, green: 0.72, blue: 0.25)
                : Color(red: 0.65, green: 0.32, blue: 0.00)
        }
        if entry.serviceIsGood {
            return colorScheme == .dark
                ? Color(red: 0.28, green: 0.85, blue: 0.52)
                : Color(red: 0.05, green: 0.45, blue: 0.18)
        } else {
            return colorScheme == .dark
                ? Color(red: 1.00, green: 0.42, blue: 0.35)
                : Color(red: 0.78, green: 0.14, blue: 0.05)
        }
    }

    private var statusTitle: String {
        if entry.isUnavailable { return "Unavailable" }
        if entry.isStale { return "Saved Status" }
        return entry.serviceIsGood ? "Good Service" : "Service Alert"
    }

    private var statusSymbol: String {
        if entry.isUnavailable { return "questionmark.circle.fill" }
        if entry.isStale { return "clock.badge.exclamationmark" }
        return entry.serviceIsGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var updateSymbol: String {
        entry.isStale ? "clock.badge.exclamationmark" : "clock"
    }

    private var beaconTitle: String {
        if entry.isUnavailable { return "OFFLINE" }
        if entry.isStale { return "SAVED" }
        return "LIVE"
    }

    private var isConfigured: Bool {
        !entry.lineID.isEmpty && entry.lineName != "Select a line"
    }

    // MARK: - Body

    var body: some View {
        Group {
            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .containerBackground(for: .widget) {
            WidgetAtmosphereBackground(
                statusColor: statusColor,
                isAlert: !entry.serviceIsGood && !entry.isUnavailable && isConfigured,
                isStale: entry.isStale,
                isUnavailable: entry.isUnavailable || !isConfigured
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Small Layout

    @ViewBuilder
    private var smallLayout: some View {
        if !isConfigured {
            unconfiguredSmallLayout
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Top Header: Brand pill + Live Beacon
                HStack(spacing: 6) {
                    brandTile(size: 20, iconSize: 10)

                    Text("METRO")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    liveBeacon
                }
                .padding(.bottom, 6)

                // Line Name with Transit Accent Bar
                HStack(alignment: .center, spacing: 5) {
                    Capsule()
                        .fill(statusColor)
                        .frame(width: 3.5, height: 14)

                    Text(entry.lineName)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(.primary)
                }
                .padding(.bottom, 6)

                // Elevated Hero Card: Status & Message
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(statusColor)

                        Text(statusTitle)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }

                    Text(entry.serviceMessage)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(entry.isUnavailable ? .secondary : .primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.07)
                        : Color.black.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark ? Color.white.opacity(0.20) : Color.white.opacity(0.65),
                                    colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )

                Spacer(minLength: 4)

                // Bottom Footer: Alerts/Works Chip + Timestamp
                HStack(spacing: 4) {
                    if entry.alertCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(entry.alertCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(statusColor.opacity(0.14), in: Capsule())
                    } else if entry.plannedWorkCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(entry.plannedWorkCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    } else if !entry.isUnavailable {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("All Clear")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(statusColor)
                    }

                    Spacer(minLength: 2)

                    updateFooter
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Medium Layout

    @ViewBuilder
    private var mediumLayout: some View {
        if !isConfigured {
            unconfiguredMediumLayout
        } else {
            HStack(alignment: .top, spacing: 12) {
                // Left Panel: Identity & Hero Status
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        brandTile(size: 22, iconSize: 11)

                        Text("METRO")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 6)

                    Text(entry.lineName)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .padding(.bottom, 6)

                    // Hero status badge
                    HStack(spacing: 5) {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 10, weight: .bold))
                        Text(statusTitle)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(statusColor.opacity(0.3), lineWidth: 0.8)
                    )

                    Spacer(minLength: 6)

                    // Telemetry pills
                    HStack(spacing: 5) {
                        if entry.alertCount > 0 {
                            Label("\(entry.alertCount) Alert\(entry.alertCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(statusColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(statusColor.opacity(0.12), in: Capsule())
                        }

                        if entry.plannedWorkCount > 0 {
                            Label("\(entry.plannedWorkCount) Work\(entry.plannedWorkCount == 1 ? "" : "s")", systemImage: "wrench.and.screwdriver.fill")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        } else if entry.alertCount == 0 && !entry.isUnavailable {
                            Label("Normal Timetable", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(statusColor)
                        }
                    }
                }
                .frame(maxWidth: 136, maxHeight: .infinity, alignment: .leading)

                // Right Panel: Elevated Live Bulletin Tile
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label(
                            entry.alertCount > 0 ? "LIVE ALERT" : "LINE BULLETIN",
                            systemImage: entry.alertCount > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill" : "info.circle.fill"
                        )
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(entry.alertCount > 0 ? statusColor : Color.secondary)

                        Spacer(minLength: 0)

                        liveBeacon
                    }

                    Text(entry.serviceMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(entry.isUnavailable ? .secondary : .primary)
                        .lineLimit(3)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)

                    if let worksTitle = entry.firstPlannedWorkTitle, entry.plannedWorkCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                            Text(worksTitle)
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }

                    Spacer(minLength: 0)

                    HStack {
                        Spacer(minLength: 0)
                        updateFooter
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark ? Color.white.opacity(0.20) : Color.white.opacity(0.55),
                                    colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Components

    private func brandTile(size: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.62, blue: 0.15),
                            Color(red: 0.88, green: 0.40, blue: 0.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Image(systemName: "tram.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var liveBeacon: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.35))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(statusColor)
                    .frame(width: 5.5, height: 5.5)
            }
            Text(beaconTitle)
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2.5)
        .background(statusColor.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(statusColor.opacity(0.25), lineWidth: 0.6)
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var updateFooter: some View {
        if let lastUpdatedAt = entry.lastUpdatedAt {
            HStack(spacing: 3) {
                Image(systemName: updateSymbol)
                    .font(.system(size: 8.5))
                    .accessibilityHidden(true)
                Text(entry.isStale ? "Saved" : "Updated")
                Text(lastUpdatedAt, style: .relative)
            }
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(entry.isStale ? Color.orange : Color.secondary)
            .lineLimit(1)
        } else {
            Label("No recent data", systemImage: "clock.badge.exclamationmark")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Unconfigured Layouts

    private var unconfiguredSmallLayout: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                brandTile(size: 20, iconSize: 10)
                Text("TRAIN STATUS")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .strokeBorder(
                        Color.orange.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "tram.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
            }

            Text("Select Train Line")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("Press & hold to edit")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unconfiguredMediumLayout: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                brandTile(size: 24, iconSize: 12)
                Text("Train Status")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                Text("Melbourne Metro")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: 120, maxHeight: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Label("SETUP REQUIRED", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.orange)

                Text("Long-press this widget and select Edit Widget to pick your Melbourne Metro train line.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Spacer(minLength: 0)

                Text("PapaTransport")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        guard isConfigured else {
            return "Train Line Status widget. Setup required. Long press to choose a train line."
        }
        var summary = "\(entry.lineName), \(statusTitle). \(entry.serviceMessage)"
        if let lastUpdatedAt = entry.lastUpdatedAt {
            summary += ". Updated \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))."
        }
        if entry.alertCount > 0 {
            summary += ". \(entry.alertCount) live alerts."
        }
        if entry.plannedWorkCount > 0 {
            summary += ". \(entry.firstPlannedWorkTitle ?? "\(entry.plannedWorkCount) planned works")"
        }
        return summary
    }
}

// MARK: - Atmosphere Background & Railway Art

struct WidgetAtmosphereBackground: View {
    let statusColor: Color
    let isAlert: Bool
    let isStale: Bool
    let isUnavailable: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var baseGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.085, green: 0.075, blue: 0.090),
                    Color(red: 0.125, green: 0.110, blue: 0.135)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.965, blue: 0.945),
                    Color(red: 0.925, green: 0.895, blue: 0.865)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var glowColor: Color {
        if isUnavailable { return .secondary }
        if isStale { return Color(red: 1.00, green: 0.65, blue: 0.20) }
        return isAlert
            ? Color(red: 0.95, green: 0.35, blue: 0.20)
            : Color(red: 0.20, green: 0.80, blue: 0.45)
    }

    private var glowOpacity: Double {
        if isUnavailable { return 0.04 }
        return colorScheme == .dark ? 0.22 : 0.13
    }

    var body: some View {
        ZStack {
            baseGradient

            // Radial ambient glow
            RadialGradient(
                colors: [
                    glowColor.opacity(glowOpacity),
                    glowColor.opacity(0.0)
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 180
            )

            // Railway track watermark
            TransitTrackArtwork(
                color: isAlert ? glowColor : Color.orange,
                colorScheme: colorScheme
            )
        }
    }
}

struct TransitTrackArtwork: View {
    let color: Color
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            // Main curved transit line
            var railPath = Path()
            railPath.move(to: CGPoint(x: w * 0.25, y: -15))
            railPath.addCurve(
                to: CGPoint(x: w + 20, y: h * 0.85),
                control1: CGPoint(x: w * 0.65, y: h * 0.10),
                control2: CGPoint(x: w * 0.85, y: h * 0.50)
            )

            // Rail line 2 (parallel track)
            var railPath2 = Path()
            railPath2.move(to: CGPoint(x: w * 0.32, y: -15))
            railPath2.addCurve(
                to: CGPoint(x: w + 20, y: h * 0.95),
                control1: CGPoint(x: w * 0.72, y: h * 0.10),
                control2: CGPoint(x: w * 0.92, y: h * 0.50)
            )

            let trackAlpha = colorScheme == .dark ? 0.08 : 0.06
            context.stroke(
                railPath,
                with: .color(color.opacity(trackAlpha)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            context.stroke(
                railPath2,
                with: .color(color.opacity(trackAlpha * 0.75)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
            )

            // Station node circles on track
            let nodePoint = CGPoint(x: w * 0.76, y: h * 0.32)
            var nodeCircle = Path()
            nodeCircle.addEllipse(in: CGRect(x: nodePoint.x - 4, y: nodePoint.y - 4, width: 8, height: 8))
            context.fill(nodeCircle, with: .color(color.opacity(trackAlpha * 1.6)))

            var nodeInner = Path()
            nodeInner.addEllipse(in: CGRect(x: nodePoint.x - 2, y: nodePoint.y - 2, width: 4, height: 4))
            context.fill(nodeInner, with: .color(colorScheme == .dark ? .black.opacity(0.4) : .white.opacity(0.8)))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Small - Good Service", as: .systemSmall) {
    TrainLineStatusWidget()
} timeline: {
    TrainLineStatusEntry(
        date: .now,
        lineID: "1",
        lineName: "Craigieburn",
        serviceIsGood: true,
        serviceMessage: "Good service on all lines.",
        alertCount: 0,
        plannedWorkCount: 0,
        firstPlannedWorkTitle: nil,
        lastUpdatedAt: .now.addingTimeInterval(-180),
        isStale: false,
        isUnavailable: false
    )
}

#Preview("Small - Service Alert", as: .systemSmall) {
    TrainLineStatusWidget()
} timeline: {
    TrainLineStatusEntry(
        date: .now,
        lineID: "2",
        lineName: "Pakenham",
        serviceIsGood: false,
        serviceMessage: "Delays of up to 15 minutes due to an equipment fault.",
        alertCount: 1,
        plannedWorkCount: 2,
        firstPlannedWorkTitle: "Weekend track works",
        lastUpdatedAt: .now.addingTimeInterval(-60),
        isStale: false,
        isUnavailable: false
    )
}

#Preview("Medium - Good Service", as: .systemMedium) {
    TrainLineStatusWidget()
} timeline: {
    TrainLineStatusEntry(
        date: .now,
        lineID: "3",
        lineName: "Flinders Street",
        serviceIsGood: true,
        serviceMessage: "Normal timetable operating across all sections.",
        alertCount: 0,
        plannedWorkCount: 1,
        firstPlannedWorkTitle: "Track maintenance Sunday evening",
        lastUpdatedAt: .now.addingTimeInterval(-120),
        isStale: false,
        isUnavailable: false
    )
}

#Preview("Medium - Service Alert", as: .systemMedium) {
    TrainLineStatusWidget()
} timeline: {
    TrainLineStatusEntry(
        date: .now,
        lineID: "4",
        lineName: "Sunbury Line",
        serviceIsGood: false,
        serviceMessage: "Major delays through North Melbourne due to signaling repairs.",
        alertCount: 2,
        plannedWorkCount: 3,
        firstPlannedWorkTitle: "Buses replace trains between Sunshine and Watergardens",
        lastUpdatedAt: .now.addingTimeInterval(-300),
        isStale: false,
        isUnavailable: false
    )
}
