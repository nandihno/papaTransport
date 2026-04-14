//
//  GTFSProtobufDecoder.swift
//  myLatest
//
//  Lightweight protobuf binary decoder — no external dependencies.
//  Supports the subset of wire types needed by GTFS-RT v2.0:
//    wire 0 = varint, wire 1 = 64-bit, wire 2 = length-delimited, wire 5 = 32-bit.
//

import Foundation

// MARK: - Wire types

enum ProtobufWireType: UInt8 {
    case varint          = 0
    case fixed64         = 1
    case lengthDelimited = 2
    case fixed32         = 5
}

// MARK: - Protobuf field (one tag+value pair)

enum ProtobufValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)
}

struct ProtobufField {
    let fieldNumber: Int
    let value: ProtobufValue
}

// MARK: - Reader

struct ProtobufReader {
    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= data.count }
    var remaining: Int { max(0, data.count - offset) }

    // MARK: - Primitives

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtobufError.malformedVarint }
        }
        throw ProtobufError.unexpectedEnd
    }

    mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ProtobufError.unexpectedEnd }
        let val = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: val)
    }

    mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw ProtobufError.unexpectedEnd }
        let val = data[offset..<offset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: val)
    }

    mutating func readBytes() throws -> Data {
        let length = Int(try readVarint())
        guard length >= 0, offset + length <= data.count else { throw ProtobufError.unexpectedEnd }
        let result = data[offset..<offset+length]
        offset += length
        return Data(result)
    }

    // MARK: - Field-level parsing

    mutating func readField() throws -> ProtobufField {
        let tag = try readVarint()
        let fieldNumber = Int(tag >> 3)
        guard let wireType = ProtobufWireType(rawValue: UInt8(tag & 0x07)) else {
            throw ProtobufError.unknownWireType(Int(tag & 0x07))
        }

        let value: ProtobufValue
        switch wireType {
        case .varint:
            value = .varint(try readVarint())
        case .fixed64:
            value = .fixed64(try readFixed64())
        case .lengthDelimited:
            value = .bytes(try readBytes())
        case .fixed32:
            value = .fixed32(try readFixed32())
        }

        return ProtobufField(fieldNumber: fieldNumber, value: value)
    }

    /// Parse all fields from the current reader position to the end.
    mutating func readAllFields() throws -> [ProtobufField] {
        var fields: [ProtobufField] = []
        while !isAtEnd {
            fields.append(try readField())
        }
        return fields
    }
}

// MARK: - Convenience extensions on ProtobufValue

extension ProtobufValue {
    var asUInt64: UInt64? {
        if case .varint(let v) = self { return v }
        return nil
    }

    var asInt32: Int32? {
        if case .varint(let v) = self { return Int32(truncatingIfNeeded: v) }
        return nil
    }

    var asInt64: Int64? {
        if case .varint(let v) = self { return Int64(bitPattern: v) }
        return nil
    }

    var asBool: Bool? {
        if case .varint(let v) = self { return v != 0 }
        return nil
    }

    var asData: Data? {
        if case .bytes(let d) = self { return d }
        return nil
    }

    var asString: String? {
        guard let d = asData else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Parse the bytes as an embedded message, returning its fields.
    func asMessage() throws -> [ProtobufField] {
        guard let d = asData else { throw ProtobufError.typeMismatch }
        var reader = ProtobufReader(data: d)
        return try reader.readAllFields()
    }
}

// MARK: - Helpers

extension Array where Element == ProtobufField {
    /// Return the first field matching the given field number.
    func first(_ number: Int) -> ProtobufValue? {
        first(where: { $0.fieldNumber == number })?.value
    }

    /// Return all fields matching the given field number (for repeated fields).
    func all(_ number: Int) -> [ProtobufValue] {
        filter { $0.fieldNumber == number }.map(\.value)
    }
}

// MARK: - Errors

enum ProtobufError: LocalizedError {
    case malformedVarint
    case unexpectedEnd
    case unknownWireType(Int)
    case typeMismatch

    var errorDescription: String? {
        switch self {
        case .malformedVarint:      return "Malformed varint in protobuf data."
        case .unexpectedEnd:        return "Unexpected end of protobuf data."
        case .unknownWireType(let t): return "Unknown protobuf wire type: \(t)."
        case .typeMismatch:         return "Protobuf value type mismatch."
        }
    }
}
