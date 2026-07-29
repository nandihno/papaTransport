import Foundation

/// Streaming RFC-4180 CSV reader that works in bytes rather than `String`.
///
/// `stop_times.txt` is ~2.7 million rows; materialising a Swift `String` for
/// every field would dominate import time. Instead each row is reported as
/// byte ranges into a buffer the reader owns, and the importer binds the ones
/// it needs straight into SQLite.
/// `nonisolated` because the target defaults to main-actor isolation — see the
/// note on `GTFSFeedImporter`.
nonisolated struct CSVRowReader {
    /// Field ranges for the current row, valid only for the duration of the
    /// callback.
    typealias RowHandler = (UnsafeRawBufferPointer, [Range<Int>]) throws -> Void

    private var buffer: [UInt8] = []
    private var scanPosition = 0
    private var rowStart = 0
    private var inQuotes = false
    /// True when the previous byte was a quote inside a quoted field, which
    /// may turn out to be an escaped quote ("") rather than a terminator.
    private var pendingQuote = false

    init() {
        buffer.reserveCapacity(1 << 20)
    }

    /// Feeds a chunk of decompressed bytes, invoking `handler` for each
    /// complete row it completes.
    mutating func consume(_ chunk: UnsafeRawBufferPointer, handler: RowHandler) throws {
        buffer.append(contentsOf: chunk)
        try drain(handler: handler)
        compact()
    }

    /// Emits any trailing row not terminated by a newline.
    mutating func finish(handler: RowHandler) throws {
        guard rowStart < buffer.count else { return }
        try emitRow(from: rowStart, to: buffer.count, handler: handler)
        buffer.removeAll(keepingCapacity: false)
        rowStart = 0
        scanPosition = 0
    }

    private mutating func drain(handler: RowHandler) throws {
        var index = scanPosition
        while index < buffer.count {
            let byte = buffer[index]

            if pendingQuote {
                pendingQuote = false
                if byte == UInt8(ascii: "\"") {
                    // Escaped quote — stay inside the quoted field.
                    index += 1
                    continue
                }
                inQuotes = false
            }

            if byte == UInt8(ascii: "\"") {
                if inQuotes {
                    pendingQuote = true
                } else {
                    inQuotes = true
                }
                index += 1
                continue
            }

            if !inQuotes && byte == UInt8(ascii: "\n") {
                var end = index
                if end > rowStart && buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                if end > rowStart {
                    try emitRow(from: rowStart, to: end, handler: handler)
                }
                index += 1
                rowStart = index
                continue
            }

            index += 1
        }
        scanPosition = index
    }

    private mutating func compact() {
        guard rowStart > 0 else { return }
        buffer.removeFirst(rowStart)
        scanPosition -= rowStart
        rowStart = 0
    }

    private func emitRow(from start: Int, to end: Int, handler: RowHandler) throws {
        var fields: [Range<Int>] = []
        fields.reserveCapacity(12)

        var fieldStart = start
        var quoted = false
        var index = start
        var sawQuote = false

        while index < end {
            let byte = buffer[index]
            if byte == UInt8(ascii: "\"") {
                sawQuote = true
                if quoted && index + 1 < end && buffer[index + 1] == UInt8(ascii: "\"") {
                    index += 2
                    continue
                }
                quoted.toggle()
                index += 1
                continue
            }
            if byte == UInt8(ascii: ",") && !quoted {
                fields.append(trimmed(fieldStart, index, stripQuotes: sawQuote))
                fieldStart = index + 1
                sawQuote = false
            }
            index += 1
        }
        fields.append(trimmed(fieldStart, end, stripQuotes: sawQuote))

        try buffer.withUnsafeBytes { raw in
            try handler(raw, fields)
        }
    }

    /// Trims padding, then drops surrounding quotes.
    ///
    /// The whitespace trim is not optional: TransLink emits `", -27.467834"`
    /// with a space after the comma, and `Double("-27.4")` rejects a leading
    /// space, so every coordinate would silently fail to parse. Whitespace is
    /// stripped before the quotes so anything genuinely inside a quoted field
    /// is preserved.
    ///
    /// Escaped inner quotes ("") are left as-is — no GTFS field this importer
    /// reads contains one, and unescaping would force a copy per field.
    private func trimmed(_ start: Int, _ end: Int, stripQuotes: Bool) -> Range<Int> {
        var lower = start
        var upper = end

        func isPadding(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
        }

        while lower < upper, isPadding(buffer[lower]) { lower += 1 }
        while upper > lower, isPadding(buffer[upper - 1]) { upper -= 1 }

        if stripQuotes,
           upper - lower >= 2,
           buffer[lower] == UInt8(ascii: "\""),
           buffer[upper - 1] == UInt8(ascii: "\"") {
            lower += 1
            upper -= 1
        }
        return lower..<upper
    }
}

// MARK: - Field helpers

nonisolated extension UnsafeRawBufferPointer {
    func string(_ range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        let slice = UnsafeRawBufferPointer(rebasing: self[range])
        return String(decoding: slice, as: UTF8.self)
    }

    func int(_ range: Range<Int>) -> Int? {
        guard !range.isEmpty else { return nil }
        var value = 0
        var negative = false
        for (offset, index) in range.enumerated() {
            let byte = self[index]
            if offset == 0 && byte == UInt8(ascii: "-") { negative = true; continue }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return negative ? -value : value
    }

    func double(_ range: Range<Int>) -> Double? {
        guard !range.isEmpty else { return nil }
        return Double(string(range))
    }

    /// `HH:MM:SS` to seconds since local midnight. GTFS legitimately exceeds
    /// 24:00:00 for trips that run past midnight, so hours are not bounded.
    func gtfsSeconds(_ range: Range<Int>) -> Int? {
        guard range.count >= 7 else { return nil }
        let colonSecond = range.upperBound - 3
        let colonFirst = range.upperBound - 6
        guard self[colonSecond] == UInt8(ascii: ":"), self[colonFirst] == UInt8(ascii: ":") else {
            return nil
        }
        guard let hours = int(range.lowerBound..<colonFirst),
              let minutes = int((colonFirst + 1)..<colonSecond),
              let seconds = int((colonSecond + 1)..<range.upperBound)
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
