import CoreLocation
import Foundation
import SQLite3

@main
struct RouteGeometryChecks {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let decoder = JSONDecoder()
        let geopath = try decoder.decode(PTVGeopath.self, from: Data(#"{"direction_id":7,"valid_from":"2026-10-01","valid_to":"2026-10-31","paths":["-37.81, 144.96 -37.82,144.97","-37.83,144.98 -37.84,144.99","-37.8,144.9 invalid,144.8","91,144 -37,145","-37,144"]}"#.utf8))
        let date = ISO8601DateFormatter().date(from: "2026-10-16T00:00:00Z")!
        let paths = geopath.coordinates(directionId: 7, on: date)
        precondition(paths.count == 2 && paths[0].count == 2)
        precondition(paths[0][0].latitude == -37.81 && paths[0][0].longitude == 144.96)
        precondition(geopath.coordinates(directionId: 8, on: date).isEmpty)
        precondition(geopath.coordinates(directionId: 7, on: date.addingTimeInterval(40 * 86400)).isEmpty)
        precondition(geopath.coordinates(directionId: 7, on: date.addingTimeInterval(-40 * 86400)).isEmpty)
        let oldRun = try decoder.decode(PTVRun.self, from: Data(#"{"run_ref":"old-run","geopath":null}"#.utf8))
        precondition(oldRun.runRef == "old-run" && oldRun.geopath.isEmpty)

        for name in ["with-shapes", "without-shapes"] {
            let path = folder.appendingPathComponent("\(name).sqlite3").path
            _ = try GTFSFeedImporter(
                archiveURL: folder.appendingPathComponent("\(name).zip"),
                destinationPath: path,
                onProgress: { _, _ in }
            ).run()
            let database = GTFSDatabase()
            try await database.openForValidation(path)
            let hasSchema = await database.hasRouteGeometrySchema()
            precondition(hasSchema)
            let bus = try await database.routeGeometry(tripId: "bus-trip")
            let train = try await database.routeGeometry(tripId: "train-trip")
            if name == "with-shapes" {
                precondition(bus.count == 1 && bus[0].count == 3)
                precondition(bus[0].map(\.latitude) == [-27.1, -27.2, -27.3])
                precondition(train.count == 1 && train[0].count == 2)
                precondition(train[0][0].longitude == 153.4)
            } else {
                precondition(bus.isEmpty && train.isEmpty)
            }
            let unknown = try await database.routeGeometry(tripId: "missing")
            precondition(unknown.isEmpty)
            let invalidShapeIds = try String(contentsOf: folder.appendingPathComponent("invalid-shapes.txt"), encoding: .utf8)
            for id in invalidShapeIds.split(separator: "\n") {
                let geometry = try await database.routeGeometry(tripId: String(id))
                precondition(geometry.isEmpty, "Malformed shape \(id) must be rejected completely")
            }
        }
        let legacy = GTFSDatabase()
        try await legacy.openForValidation(folder.appendingPathComponent("legacy.sqlite3").path)
        let legacyHasSchema = await legacy.hasRouteGeometrySchema()
        let legacyGeometry = try await legacy.routeGeometry(tripId: "bus-trip")
        precondition(!legacyHasSchema && legacyGeometry.isEmpty)
        let malformed = GTFSDatabase()
        try await malformed.openForValidation(folder.appendingPathComponent("malformed.sqlite3").path)
        for id in ["bad-coordinate", "bad-sequence", "duplicate-sequence"] {
            let geometry = try await malformed.routeGeometry(tripId: id)
            precondition(geometry.isEmpty, "Malformed database shape \(id) must not draw a connecting line")
        }
        print("Passed: PTV segments, coordinate order, invalid points, direction/date filtering, old payload decoding; QLD streamed shapes, bus/rail queries, point order, unknown trips, optional shapes, legacy database, whole-shape rejection for malformed/nonfinite coordinates and invalid/overflowing sequences, and corrupt database rows.")
    }
}
