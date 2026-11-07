import SwiftUI

/// A vehicle paired with the board departure it is working, if any.
///
/// Exists so the trip lookup happens **once per render** rather than once per
/// vehicle. Referencing a computed `[tripId: departure]` dictionary from inside
/// a `ForEach` rebuilds that whole dictionary for every element — with 250
/// vehicles against a 150-departure board that was ~37,000 insertions on the
/// main thread per render pass, and it made the map controls miss taps.
struct VehicleAnnotation: Identifiable {
    let vehicle: LiveVehicle
    let stopId: String?
    let departure: BusDeparture?

    var id: String { vehicle.id }
    var isTappable: Bool { stopId != nil && departure != nil }
}

extension Array where Element == LiveVehicle {
    /// Pairs each vehicle with its board departure, building the index once.
    func annotations(matching stops: [NearbyBusStop]) -> [VehicleAnnotation] {
        var index: [String: (stopId: String, departure: BusDeparture)] = [:]
        for stop in stops {
            for departure in stop.departures where index[departure.tripId] == nil {
                index[departure.tripId] = (stop.id, departure)
            }
        }
        return map { vehicle in
            let match = index[vehicle.tripId]
            return VehicleAnnotation(
                vehicle: vehicle,
                stopId: match?.stopId,
                departure: match?.departure
            )
        }
    }
}

/// A live vehicle on the map. Deliberately smaller and flatter than a stop pin
/// — vehicles are ambient context, stops are the thing you tap.
struct LiveVehicleMapPin: View {
    let vehicle: LiveVehicle
    /// Nil when this vehicle's trip is not on the current board, which leaves
    /// the pin non-interactive rather than offering a tap that does nothing.
    /// Common in Queensland, whose feed is network-wide.
    var onTap: (() -> Void)?

    @Environment(\.themePalette) private var palette

    private var tint: Color {
        vehicle.isStopped ? palette.textTertiary : palette.info
    }

    // The heading arrow renders only when the feed actually supplies a bearing,
    // which differs by region: PTV populates it, TransLink does not (verified
    // 2026-07-29 — 0 of 51 rail and 0 of 1083 SEQ bus vehicles carried one).
    // So Victorian vehicles point, Queensland vehicles are plain dots.
    var body: some View {
        if let onTap {
            // Only the tappable variant gets an enlarged touch target: an 18pt
            // dot is well under the 44pt minimum.
            Button(action: onTap) {
                pin
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Highlights this service on the map and in the departure list.")
        } else {
            // Ambient only. Without this a screen full of Queensland vehicles —
            // most of which resolve to no board departure — puts hundreds of
            // dead hit-test targets over the map and swallows pan gestures.
            pin
                .allowsHitTesting(false)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var pin: some View {
        ZStack {
            if let bearing = vehicle.bearing, !vehicle.isStopped {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(bearing))
                    .offset(y: -14)
            }

            Circle()
                .fill(tint)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)

            Image(systemName: vehicle.isRail ? "tram.fill" : "bus.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var accessibilityLabel: String {
        let mode = vehicle.isRail ? "Train" : "Bus"
        return vehicle.routeLabel.isEmpty ? mode : "\(mode) \(vehicle.routeLabel)"
    }
}
