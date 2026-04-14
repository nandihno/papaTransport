import Foundation

struct GTFSStop {
    let stopId: String
    let stopName: String
    let stopCode: String?
    let stopLat: Double
    let stopLon: Double
    let locationType: Int
    let parentStation: String?
}

enum GTFSDBError: LocalizedError {
    case bundledAssetMissing
    case notReady
    case openFailed
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledAssetMissing:
            return "The bundled timetable database is missing from the app package."
        case .notReady:
            return "The timetable database is not ready yet."
        case .openFailed:
            return "The timetable database could not be opened."
        case .queryFailed(let message):
            return "A timetable query failed: \(message)"
        }
    }
}
