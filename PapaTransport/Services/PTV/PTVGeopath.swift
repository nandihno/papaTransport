import CoreLocation
import Foundation

/// PTV's paths are space-separated latitude/longitude pairs, with a comma
/// between each pair's components. Each path is a separate map segment.
nonisolated struct PTVGeopath: Decodable, Sendable {
    let directionId: Int?
    let validFrom: String?
    let validTo: String?
    let paths: [String]

    private enum CodingKeys: String, CodingKey {
        case directionId = "direction_id"
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case paths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directionId = try? c.decodeIfPresent(Int.self, forKey: .directionId)
        validFrom = try? c.decodeIfPresent(String.self, forKey: .validFrom)
        validTo = try? c.decodeIfPresent(String.self, forKey: .validTo)
        paths = (try? c.decodeIfPresent([String].self, forKey: .paths)) ?? []
    }

    func coordinates(directionId: Int?, on date: Date = Date()) -> [[CLLocationCoordinate2D]] {
        if let directionId, let pathDirection = self.directionId, directionId != pathDirection { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Australia/Melbourne")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        if let validFrom, day < String(validFrom.prefix(10)) { return [] }
        if let validTo, day > String(validTo.prefix(10)) { return [] }

        return paths.compactMap { path in
            let components = path.split { $0.isWhitespace || $0 == "," }
            guard components.count >= 4, components.count.isMultiple(of: 2) else { return nil }
            var coordinates: [CLLocationCoordinate2D] = []
            coordinates.reserveCapacity(components.count / 2)
            for index in stride(from: 0, to: components.count, by: 2) {
                guard let latitude = Double(components[index]),
                      let longitude = Double(components[index + 1]),
                      latitude.isFinite, longitude.isFinite,
                      (-90...90).contains(latitude), (-180...180).contains(longitude)
                else { return nil }
                coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }
            return coordinates
        }
    }
}
