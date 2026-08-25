//  MessagePack.swift
//  BoffinStructure
//
//  The container format BinaryCIF is written in.
//
//  Vendoring a MessagePack library for this would be a dependency, a licence to
//  audit and a supply chain, in exchange for about two hundred lines. The subset
//  BinaryCIF uses is small and fixed: maps, arrays, strings, integers, floats,
//  binary blobs, booleans and nil. Everything else in the specification (the
//  extension types, timestamps) never appears in a structure file, and a decoder
//  that refuses them loudly is safer than one that guesses.

import Foundation

/// A decoded MessagePack value.
public indirect enum MessagePackValue: Sendable {
    case nilValue
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([String: MessagePackValue])
}

public enum MessagePackError: Error, Sendable {
    case truncated(at: Int)
    case unsupportedFormat(UInt8, at: Int)
    case nonStringMapKey(at: Int)
}

public enum MessagePack {

    /// Decode one value from the start of `data`.
    public static func decode(_ data: Data) throws -> MessagePackValue {
        var reader = Reader(data: data)
        return try reader.value()
    }

    struct Reader {
        let data: Data
        var offset: Int = 0

        init(data: Data) { self.data = data }

        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw MessagePackError.truncated(at: offset) }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard offset + count <= data.count else {
                throw MessagePackError.truncated(at: offset)
            }
            defer { offset += count }
            let start = data.startIndex + offset
            return data[start..<(start + count)]
        }

        mutating func unsigned(_ width: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<width { value = value << 8 | UInt64(try byte()) }
            return value
        }

        mutating func value() throws -> MessagePackValue {
            let start = offset
            let tag = try byte()
            switch tag {
            case 0x00...0x7F: return .uint(UInt64(tag))
            case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: tag)))
            case 0x80...0x8F: return try map(count: Int(tag & 0x0F))
            case 0x90...0x9F: return try array(count: Int(tag & 0x0F))
            case 0xA0...0xBF: return .string(try text(count: Int(tag & 0x1F)))
            case 0xC0: return .nilValue
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4: return .binary(try bytes(Int(try unsigned(1))))
            case 0xC5: return .binary(try bytes(Int(try unsigned(2))))
            case 0xC6: return .binary(try bytes(Int(try unsigned(4))))
            case 0xCA:
                return .float(Double(Float(bitPattern: UInt32(try unsigned(4)))))
            case 0xCB:
                return .float(Double(bitPattern: try unsigned(8)))
            case 0xCC: return .uint(try unsigned(1))
            case 0xCD: return .uint(try unsigned(2))
            case 0xCE: return .uint(try unsigned(4))
            case 0xCF: return .uint(try unsigned(8))
            case 0xD0: return .int(Int64(Int8(bitPattern: UInt8(try unsigned(1)))))
            case 0xD1: return .int(Int64(Int16(bitPattern: UInt16(try unsigned(2)))))
            case 0xD2: return .int(Int64(Int32(bitPattern: UInt32(try unsigned(4)))))
            case 0xD3: return .int(Int64(bitPattern: try unsigned(8)))
            case 0xD9: return .string(try text(count: Int(try unsigned(1))))
            case 0xDA: return .string(try text(count: Int(try unsigned(2))))
            case 0xDB: return .string(try text(count: Int(try unsigned(4))))
            case 0xDC: return try array(count: Int(try unsigned(2)))
            case 0xDD: return try array(count: Int(try unsigned(4)))
            case 0xDE: return try map(count: Int(try unsigned(2)))
            case 0xDF: return try map(count: Int(try unsigned(4)))
            default:
                throw MessagePackError.unsupportedFormat(tag, at: start)
            }
        }

        mutating func text(count: Int) throws -> String {
            // Not `String(data:encoding:)`, which returns nil for anything that
            // is not valid UTF-8 and would turn one bad byte into a missing
            // column. Lossy decoding keeps the row and corrupts one character.
            String(decoding: try bytes(count), as: UTF8.self)
        }

        mutating func array(count: Int) throws -> MessagePackValue {
            var values: [MessagePackValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try value()) }
            return .array(values)
        }

        mutating func map(count: Int) throws -> MessagePackValue {
            var pairs: [String: MessagePackValue] = [:]
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let start = offset
                guard case .string(let key) = try value() else {
                    throw MessagePackError.nonStringMapKey(at: start)
                }
                pairs[key] = try value()
            }
            return .map(pairs)
        }
    }
}

extension MessagePackValue {
    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): Int(value)
        case .uint(let value): Int(value)
        case .float(let value): Int(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .float(let value): value
        case .int(let value): Double(value)
        case .uint(let value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        if case .binary(let value) = self { return value }
        return nil
    }

    public var arrayValue: [MessagePackValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var mapValue: [String: MessagePackValue]? {
        if case .map(let pairs) = self { return pairs }
        return nil
    }

    public subscript(key: String) -> MessagePackValue? { mapValue?[key] }
}
