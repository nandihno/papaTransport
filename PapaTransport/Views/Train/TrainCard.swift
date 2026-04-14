//
//  TrainCard.swift
//  myLatest
//

import SwiftUI

// MARK: - Train Card

struct TrainCard: View {
    let train: TrainInfo
    @Environment(\.themePalette) private var palette
    @State private var showHomeStation = true
    @State private var showCityStation = false
    @State private var showPlannedWorks = false
    @State private var planAheadEnabled = false
    @State private var planAheadTime = Date()
    @State private var cityPlanAheadEnabled = false
    @State private var cityPlanAheadTime = Date()

    /// Seconds-since-midnight for the chosen plan-ahead time in Melbourne.
    private var planAheadChosenSeconds: Int {
        let mel = TimeZone(identifier: "Australia/Melbourne")!
        var cal = Calendar.current
        cal.timeZone = mel
        let comps = cal.dateComponents([.hour, .minute, .second], from: planAheadTime)
        return (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
    }

    /// Departures filtered to 1h before / 2h after the chosen plan-ahead time.
    private var planAheadDepartures: [TrainDeparture] {
        let minSeconds = planAheadChosenSeconds - 3600
        let maxSeconds = planAheadChosenSeconds + 7200
        return train.homeStationAllDepartures.filter {
            $0.estimatedDepartureSeconds >= minSeconds &&
            $0.estimatedDepartureSeconds <= maxSeconds
        }
    }

    /// Human-readable label for the plan-ahead time window.
    private var planAheadWindowLabel: String {
        let fromStr = TrainService.secondsToTimeString(planAheadChosenSeconds - 3600)
        let toStr   = TrainService.secondsToTimeString(planAheadChosenSeconds + 7200)
        return "\(fromStr) – \(toStr)"
    }

    // ── City station Plan Ahead ──────────────────────────────────────

    private var cityPlanAheadChosenSeconds: Int {
        let mel = TimeZone(identifier: "Australia/Melbourne")!
        var cal = Calendar.current
        cal.timeZone = mel
        let comps = cal.dateComponents([.hour, .minute, .second], from: cityPlanAheadTime)
        return (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
    }

    /// City outbound departures filtered to 1h before / 2h after the chosen time.
    private var cityPlanAheadDepartures: [TrainDeparture] {
        let minSeconds = cityPlanAheadChosenSeconds - 3600
        let maxSeconds = cityPlanAheadChosenSeconds + 7200
        return train.cityStationAllDepartures.filter {
            $0.estimatedDepartureSeconds >= minSeconds &&
            $0.estimatedDepartureSeconds <= maxSeconds
        }
    }

    private var cityPlanAheadWindowLabel: String {
        let fromStr = TrainService.secondsToTimeString(cityPlanAheadChosenSeconds - 3600)
        let toStr   = TrainService.secondsToTimeString(cityPlanAheadChosenSeconds + 7200)
        return "\(fromStr) – \(toStr)"
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ────────────────────────────────────────────────
                HStack {
                    Label("Train Status", systemImage: "tram.fill")
                        .font(.transit(14, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Spacer()
                    Label(train.melbourneTimeAtFetch, systemImage: "clock")
                        .font(.transit(11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.surfaceRaised, in: Capsule())
                }

                // ── Line name + service status ────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text(train.lineName)
                        .font(.transit(24, weight: .heavy))
                        .foregroundStyle(palette.textPrimary)

                    if train.serviceIsGood {
                        Label(train.serviceStatusMessage, systemImage: "checkmark.circle.fill")
                            .font(.transit(13, weight: .bold))
                            .foregroundStyle(AppTheme.success)
                            .lineLimit(2)
                    } else {
                        ForEach(train.alerts) { alert in
                            TrainAlertRow(alert: alert)
                        }
                        if train.alerts.isEmpty {
                            Text(train.serviceStatusMessage)
                                .font(.caption)
                                .foregroundStyle(AppTheme.warning)
                        }
                    }
                }

                // ── Home station departures (collapsible) ─────────────────
                if !train.homeStationName.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showHomeStation) {
                        VStack(alignment: .leading, spacing: 8) {
                            // Current departures
                            DepartureSectionView(stationName:      train.homeStationName,
                                                departures:       train.homeStationDepartures,
                                                splitByDirection: true,
                                                showHeader:       false)

                            Divider()

                            // Plan Ahead toggle + time picker
                            HStack {
                                Label("Plan Ahead", systemImage: "clock.arrow.2.circlepath")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Toggle("", isOn: $planAheadEnabled)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                            }

                            if planAheadEnabled {
                                HStack(spacing: 8) {
                                    Text("Departures around")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    DatePicker("",
                                               selection: $planAheadTime,
                                               in: Date()...,
                                               displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                        .environment(\.timeZone, TimeZone(identifier: "Australia/Melbourne")!)
                                }

                                Text("Showing: \(planAheadWindowLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                DepartureSectionView(stationName:      train.homeStationName,
                                                    departures:       planAheadDepartures,
                                                    splitByDirection: true,
                                                    showHeader:       false)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("From \(train.homeStationName)", systemImage: "mappin.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                // ── City station departures (collapsible) ─────────────────
                if !train.cityStationName.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showCityStation) {
                        VStack(alignment: .leading, spacing: 8) {
                            DepartureSectionView(stationName:      train.cityStationName,
                                                departures:       train.cityStationDepartures,
                                                splitByDirection: true,
                                                showHeader:       false)

                            Divider()

                            // Plan Ahead toggle + time picker
                            HStack {
                                Label("Plan Ahead", systemImage: "clock.arrow.2.circlepath")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Toggle("", isOn: $cityPlanAheadEnabled)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                            }

                            if cityPlanAheadEnabled {
                                HStack(spacing: 8) {
                                    Text("Departures around")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    DatePicker("",
                                               selection: $cityPlanAheadTime,
                                               in: Date()...,
                                               displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                        .environment(\.timeZone, TimeZone(identifier: "Australia/Melbourne")!)
                                }

                                Text("Showing: \(cityPlanAheadWindowLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                DepartureSectionView(stationName:      train.cityStationName,
                                                    departures:       cityPlanAheadDepartures,
                                                    splitByDirection: true,
                                                    showHeader:       false)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("From \(train.cityStationName)", systemImage: "mappin.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Planned works (collapsible) ───────────────────────────
                if !train.plannedWorks.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showPlannedWorks) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(train.plannedWorks) { work in
                                TrainPlannedWorkRow(work: work)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("Planned Works (\(train.plannedWorks.count))",
                              systemImage: "wrench.and.screwdriver")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Train Alert Row

struct TrainAlertRow: View {
    let alert: TrainServiceAlert
    @Environment(\.themePalette) private var palette

    private var alertColor: Color {
        switch alert.alertType.lowercased() {
        case "major": return AppTheme.danger
        case "minor": return AppTheme.warning
        default:      return palette.accentStrong
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(alertColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                if let mins = alert.additionalTravelMinutes, mins > 0 {
                    Text("Allow +\(mins) min")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(alertColor)
                }
                if let due = alert.disruptionDueTo {
                    Text("Due to \(due)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(alert.plainText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Departure Section

struct DepartureSectionView: View {
    let stationName: String
    let departures: [TrainDeparture]
    @Environment(\.themePalette) private var palette
    /// When true the list is split into separate Inbound / Outbound sub-sections.
    var splitByDirection: Bool = false
    /// When false, the "From <station>" header is hidden (useful when a parent DisclosureGroup already shows it).
    var showHeader: Bool = true

    private var inbound:  [TrainDeparture] { departures.filter {  $0.isToCity } }
    private var outbound: [TrainDeparture] { departures.filter { !$0.isToCity } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            if showHeader {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption)
                        .foregroundStyle(palette.accent)
                    Text("From \(stationName)")
                        .font(.transit(13, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            if splitByDirection {
                directionSubSection(label:  "Inbound → City",
                                    color:  AppTheme.info,
                                    symbol: "arrow.up.circle.fill",
                                    rows:   inbound)
                directionSubSection(label:  "Outbound → Home",
                                    color:  palette.accent,
                                    symbol: "arrow.down.circle.fill",
                                    rows:   outbound)
            } else {
                if departures.isEmpty {
                    Text("No upcoming departures found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    departureTable(departures)
                }
            }
        }
    }

    // MARK: Sub-section for one direction

    @ViewBuilder
    private func directionSubSection(label: String,
                                     color: Color,
                                     symbol: String,
                                     rows: [TrainDeparture]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(label)
                    .foregroundStyle(color)
            }
            .font(.caption2.weight(.semibold))

            if rows.isEmpty {
                Text("No upcoming trains")
                    .font(.caption2)
                    .foregroundStyle(palette.textTertiary)
                    .italic()
                    .padding(.leading, 4)
            } else {
                departureTable(rows)
            }
        }
    }

    // MARK: Shared table renderer

    private func departureTable(_ rows: [TrainDeparture]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            // Column headers
            GridRow {
                Text("Time")    .gridColumnAlignment(.leading)
                Text("Plat")    .gridColumnAlignment(.center)
                Text("ETA")     .gridColumnAlignment(.leading)
                Text("ETD")     .gridColumnAlignment(.leading)
                Text("Dir")     .gridColumnAlignment(.leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.textTertiary)

            // One row per departure
            ForEach(rows) { dep in
                GridRow {
                    Text(dep.scheduledTimeStr)
                    Text(dep.estimatedPlatform).frame(maxWidth: .infinity, alignment: .center)
                    Text(dep.estimatedArrivalStr)
                    Text(dep.estimatedDepartureStr)
                    directionView(dep.isToCity)
                }
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func directionView(_ isToCity: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isToCity ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(isToCity ? AppTheme.info : palette.accent)
            Text(isToCity ? "In" : "Out")
        }
        .font(.caption2)
    }
}

// MARK: - Planned Work Row

struct TrainPlannedWorkRow: View {
    let work: TrainPlannedWork
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette

    private var badge: (text: String, color: Color) {
        work.upcomingCurrent.lowercased() == "current"
            ? ("Current",  .orange)
            : ("Upcoming", .blue)
    }

    var body: some View {
        Button {
            if let url = URL(string: work.link), !work.link.isEmpty { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(badge.text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(0.15))
                    .foregroundStyle(badge.color)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 2) {
                    Text(work.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !work.affectedStations.isEmpty {
                        Text(work.affectedStations.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                    if !work.link.isEmpty {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundStyle(palette.textTertiary)
                    }
                }
            }
        .buttonStyle(.plain)
    }
}
