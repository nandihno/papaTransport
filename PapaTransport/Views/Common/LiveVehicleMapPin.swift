import SwiftUI

/// A live vehicle on the map. Deliberately smaller and flatter than a stop pin
/// — vehicles are ambient context, stops are the thing you tap.
struct LiveVehicleMapPin: View {
    let vehicle: LiveVehicle

    @Environment(\.themePalette) private var palette

    private var tint: Color {
        vehicle.isStopped ? palette.textTertiary : palette.info
    }

    // No heading indicator: TransLink populates neither `bearing` nor `speed`
    // on the SEQ VehiclePositions feed (verified 2026-07-29 — 0 of 51 rail and
    // 0 of 1083 bus vehicles carried either). `LiveVehicle.bearing` is kept
    // because the GTFS-RT spec defines it and other feeds do supply it.
    var body: some View {
        ZStack {
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
        .accessibilityLabel(
            vehicle.routeLabel.isEmpty
                ? (vehicle.isRail ? "Train" : "Bus")
                : "\(vehicle.isRail ? "Train" : "Bus") \(vehicle.routeLabel)"
        )
    }
}
