import Compression
import Foundation

/// A deliberately minimal ZIP reader, in the same spirit as `ProtobufReader`:
/// the project takes no external dependencies, and the one archive it has to
/// read is simple. Verified against SEQ_GTFS.zip — no zip64, no data
/// descriptors, no encryption, every entry DEFLATE.
///
/// Entries are streamed rather than returned whole: `stop_times.txt` alone is
/// ~153 MB uncompressed, which must never be resident in memory on device.
/// `nonisolated` because the target defaults to main-actor isolation — see the
/// note on `GTFSFeedImporter`. Inflating 153 MB must not touch the main thread.
nonisolated struct ZipArchive {
    struct Entry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let isDeflated: Bool
        fileprivate let localHeaderOffset: Int
    }

    enum ZipError: LocalizedError {
        case notAZipArchive
        case unsupportedEntry(String)
        case corruptEntry(String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                "The downloaded timetable file is not a valid archive."
            case .unsupportedEntry(let name):
                "The archive entry \(name) uses an unsupported compression method."
            case .corruptEntry(let name):
                "The archive entry \(name) could not be read."
            case .checksumMismatch(let name):
                "The archive entry \(name) failed its integrity check."
            }
        }
    }

    let entries: [Entry]
    private let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileSize = Int(try handle.seekToEnd())

        // The End of Central Directory record lives in the last 64 KB (its
        // trailing comment is bounded by 0xFFFF).
        let tailLength = min(fileSize, 65_536 + 22)
        try handle.seek(toOffset: UInt64(fileSize - tailLength))
        guard let tail = try handle.read(upToCount: tailLength) else {
            throw ZipError.notAZipArchive
        }

        guard let eocd = Self.lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else {
            throw ZipError.notAZipArchive
        }

        let entryCount = Int(tail.u16(eocd + 10))
        let directoryOffset = Int(tail.u32(eocd + 16))
        let directorySize = Int(tail.u32(eocd + 12))

        try handle.seek(toOffset: UInt64(directoryOffset))
        guard let directory = try handle.read(upToCount: directorySize) else {
            throw ZipError.notAZipArchive
        }

        var parsed: [Entry] = []
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count,
                  directory.u32(cursor) == 0x0201_4B50
            else { break }

            let method = directory.u16(cursor + 10)
            let crc = directory.u32(cursor + 16)
            let compressed = Int(directory.u32(cursor + 20))
            let uncompressed = Int(directory.u32(cursor + 24))
            let nameLength = Int(directory.u16(cursor + 28))
            let extraLength = Int(directory.u16(cursor + 30))
            let commentLength = Int(directory.u16(cursor + 32))
            let localOffset = Int(directory.u32(cursor + 42))

            let nameStart = directory.startIndex + cursor + 46
            let name = String(
                data: directory[nameStart..<(nameStart + nameLength)],
                encoding: .utf8
            ) ?? ""

            if !name.isEmpty && !name.hasSuffix("/") {
                parsed.append(
                    Entry(
                        name: name,
                        compressedSize: compressed,
                        uncompressedSize: uncompressed,
                        crc32: crc,
                        isDeflated: method == 8,
                        localHeaderOffset: localOffset
                    )
                )
            }

            cursor += 46 + nameLength + extraLength + commentLength
        }

        self.entries = parsed
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Inflates `entry`, handing decompressed bytes to `onChunk` as they are
    /// produced. Throws if the CRC of the reconstructed data does not match.
    func stream(_ entry: Entry, onChunk: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard entry.isDeflated || entry.compressedSize == entry.uncompressedSize else {
            throw ZipError.unsupportedEntry(entry.name)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        // Local header: name and extra lengths differ from the central copy.
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              header.u32(0) == 0x0403_4B50
        else { throw ZipError.corruptEntry(entry.name) }

        let dataOffset = entry.localHeaderOffset + 30
            + Int(header.u16(26)) + Int(header.u16(28))
        try handle.seek(toOffset: UInt64(dataOffset))

        var crc = CRC32()

        guard entry.isDeflated else {
            // Stored: copy through in chunks.
            var remaining = entry.compressedSize
            while remaining > 0 {
                let take = min(remaining, 1 << 16)
                guard let chunk = try handle.read(upToCount: take), !chunk.isEmpty else {
                    throw ZipError.corruptEntry(entry.name)
                }
                try chunk.withUnsafeBytes { buffer in
                    crc.update(buffer)
                    try onChunk(buffer)
                }
                remaining -= chunk.count
            }
            guard crc.value == entry.crc32 else {
                throw ZipError.checksumMismatch(entry.name)
            }
            return
        }

        try inflate(handle: handle, entry: entry) { buffer in
            crc.update(buffer)
            try onChunk(buffer)
        }

        guard crc.value == entry.crc32 else {
            throw ZipError.checksumMismatch(entry.name)
        }
    }

    private func inflate(
        handle: FileHandle,
        entry: Entry,
        onChunk: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let inputCapacity = 1 << 16
        let outputCapacity = 1 << 18

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }

        // COMPRESSION_ZLIB is Apple's name for raw DEFLATE, which is exactly
        // what ZIP method 8 stores — no zlib wrapper to strip.
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { throw ZipError.corruptEntry(entry.name) }
        defer { compression_stream_destroy(streamPointer) }

        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer { output.deallocate() }

        // The compression stream holds `src_ptr` across calls, so the input has
        // to live in a buffer we own — a pointer into a Data's storage would
        // dangle the moment `withUnsafeBytes` returned.
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        defer { input.deallocate() }

        var remainingInput = entry.compressedSize
        var reachedEnd = false

        streamPointer.pointee.src_ptr = UnsafePointer(input)
        streamPointer.pointee.src_size = 0
        streamPointer.pointee.dst_ptr = output
        streamPointer.pointee.dst_size = outputCapacity

        while !reachedEnd {
            if streamPointer.pointee.src_size == 0 && remainingInput > 0 {
                let take = min(remainingInput, inputCapacity)
                guard let chunk = try handle.read(upToCount: take), !chunk.isEmpty else {
                    throw ZipError.corruptEntry(entry.name)
                }
                chunk.copyBytes(to: input, count: chunk.count)
                streamPointer.pointee.src_ptr = UnsafePointer(input)
                streamPointer.pointee.src_size = chunk.count
                remainingInput -= chunk.count
            }

            let flags = remainingInput == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(streamPointer, flags)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw ZipError.corruptEntry(entry.name)
            }

            let produced = outputCapacity - streamPointer.pointee.dst_size
            if produced > 0 {
                try onChunk(UnsafeRawBufferPointer(start: output, count: produced))
                streamPointer.pointee.dst_ptr = output
                streamPointer.pointee.dst_size = outputCapacity
            }

            if status == COMPRESSION_STATUS_END { reachedEnd = true }
        }
    }

    private static func lastIndex(of signature: [UInt8], in data: Data) -> Int? {
        guard data.count >= signature.count else { return nil }
        var index = data.count - signature.count
        while index >= 0 {
            var matched = true
            for offset in 0..<signature.count where data[data.startIndex + index + offset] != signature[offset] {
                matched = false
                break
            }
            if matched { return index }
            index -= 1
        }
        return nil
    }
}

// MARK: - Little-endian field reads

nonisolated private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}

// MARK: - CRC32

/// A 27 MB download that silently truncates would poison the timetable, so
/// every entry is checksummed as it inflates.
nonisolated struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var current = state
        for byte in buffer {
            current = Self.table[Int((current ^ UInt32(byte)) & 0xFF)] ^ (current >> 8)
        }
        state = current
    }
}
