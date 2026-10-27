import Foundation

/// One JSON dialect for the wire and the on-device files: ISO 8601 dates, with or without
/// fractional seconds (the backend writes them with).
enum JSONCoding {
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            // Files keep milliseconds. Snap to that grid so decode(encode(x)) == x exactly.
            func snapped(_ date: Date) -> Date {
                Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
            }
            if let date = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return snapped(date)
            }
            if let date = try? Date(s, strategy: .iso8601) {
                return snapped(date)
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(s)")
            )
        }
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            )
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
