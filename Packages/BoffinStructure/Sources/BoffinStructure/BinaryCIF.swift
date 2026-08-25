//  BinaryCIF.swift
//  BoffinStructure
//
//  Decoding BinaryCIF, the PDB's compact structure format.
//
//  Why BinaryCIF and not mmCIF
//  ---------------------------
//  The build plan prefers it for size and parse speed, and both are real: 1UBQ
//  is 158 KB as BinaryCIF against about 1 MB of text mmCIF, and there is no
//  tokenising to do. The cost is that the file is a MessagePack document whose
//  columns are compressed by a CHAIN of encodings, applied in order and undone
//  in reverse, and getting that order wrong produces arrays of exactly the right
//  length full of plausible-looking coordinates.
//
//  Encodings, in the order the specification defines them:
//
//    ByteArray             raw values of a fixed width
//    FixedPoint            integers divided by a factor to recover decimals
//    IntervalQuantization   integers indexing a range in equal steps
//    RunLength             pairs of (value, repeat count)
//    Delta                 first-differences from an origin
//    IntegerPacking        wide integers split across narrow ones, with the
//                          extreme value meaning "continue into the next"
//    StringArray           indices into a concatenated string blob
//
//  Every one of them is exercised by an ordinary PDB entry, so a decoder that
//  handles only the common ones fails on the next file rather than on this one.

import Foundation

public enum BinaryCIFError: Error, Sendable {
    case notBinaryCIF(String)
    case unsupportedEncoding(String)
    case malformed(String)
}

/// A decoded column: values as strings, plus the mask that says which are
/// absent (`.`) or unknown (`?`).
public struct CIFColumn: Sendable {
    public let name: String
    public let strings: [String]
    /// 0 present, 1 `.` (not applicable), 2 `?` (unknown).
    public let mask: [UInt8]

    public func string(_ row: Int) -> String? {
        guard row < strings.count else { return nil }
        if row < mask.count, mask[row] != 0 { return nil }
        return strings[row]
    }

    public func int(_ row: Int) -> Int? { string(row).flatMap { Int($0) } }
    public func double(_ row: Int) -> Double? { string(row).flatMap { Double($0) } }
}

public struct CIFCategory: Sendable {
    public let name: String
    public let rowCount: Int
    public let columns: [String: CIFColumn]

    public subscript(column: String) -> CIFColumn? { columns[column] }
}

public struct BinaryCIFFile: Sendable {
    public let header: String
    public let categories: [String: CIFCategory]

    public subscript(category: String) -> CIFCategory? { categories[category] }
}

public enum BinaryCIF {

    /// Decode the first data block of a BinaryCIF file.
    public static func decode(_ data: Data) throws -> BinaryCIFFile {
        let root = try MessagePack.decode(data)
        guard let blocks = root["dataBlocks"]?.arrayValue, let block = blocks.first else {
            throw BinaryCIFError.notBinaryCIF("no dataBlocks")
        }
        let header = block["header"]?.stringValue ?? ""
        guard let rawCategories = block["categories"]?.arrayValue else {
            throw BinaryCIFError.notBinaryCIF("no categories")
        }

        var categories: [String: CIFCategory] = [:]
        for raw in rawCategories {
            guard let name = raw["name"]?.stringValue,
                let rawColumns = raw["columns"]?.arrayValue
            else { continue }
            let rowCount = raw["rowCount"]?.intValue ?? 0

            var columns: [String: CIFColumn] = [:]
            for rawColumn in rawColumns {
                guard let columnName = rawColumn["name"]?.stringValue,
                    let dataField = rawColumn["data"]
                else { continue }
                let values = try decodeStrings(dataField, rowCount: rowCount)
                let mask = try decodeMask(rawColumn["mask"], rowCount: rowCount)
                columns[columnName] = CIFColumn(
                    name: columnName, strings: values, mask: mask)
            }
            categories[name] = CIFCategory(
                name: name, rowCount: rowCount, columns: columns)
        }
        return BinaryCIFFile(header: header, categories: categories)
    }

    // MARK: - Encoded data

    private static func decodeMask(
        _ field: MessagePackValue?, rowCount: Int
    ) throws -> [UInt8] {
        guard let field, case .map = field else {
            return [UInt8](repeating: 0, count: rowCount)
        }
        let values = try decodeNumbers(field)
        return values.map { UInt8(clamping: Int($0)) }
    }

    /// Decode a column's data field into strings, whatever it was encoded as.
    static func decodeStrings(
        _ field: MessagePackValue, rowCount: Int
    ) throws -> [String] {
        guard let encodings = field["encoding"]?.arrayValue,
            let bytes = field["data"]?.dataValue
        else {
            throw BinaryCIFError.malformed("column data has no encoding")
        }

        // A StringArray is always the OUTERMOST encoding when present, so it is
        // handled here rather than inside the numeric chain: its output is
        // strings and everything else's is numbers.
        if let last = encodings.last, last["kind"]?.stringValue == "StringArray" {
            return try decodeStringArray(last, data: bytes, remaining: encodings.dropLast())
        }

        let numbers = try applyChain(encodings, to: bytes)
        return numbers.map { value in
            // Integers print without a decimal point, which matters: an author
            // sequence number rendered as "12.0" fails to parse as an Int and
            // silently becomes a missing residue number.
            value == value.rounded() && abs(value) < 1e15
                ? String(Int64(value)) : String(value)
        }
    }

    private static func decodeNumbers(_ field: MessagePackValue) throws -> [Double] {
        guard let encodings = field["encoding"]?.arrayValue,
            let bytes = field["data"]?.dataValue
        else {
            throw BinaryCIFError.malformed("field has no encoding")
        }
        return try applyChain(encodings, to: bytes)
    }

    private static func decodeStringArray(
        _ encoding: MessagePackValue, data: Data,
        remaining: ArraySlice<MessagePackValue>
    ) throws -> [String] {
        guard let stringData = encoding["stringData"]?.stringValue,
            let offsetBytes = encoding["offsets"]?.dataValue,
            let offsetEncoding = encoding["offsetEncoding"]?.arrayValue,
            let dataEncoding = encoding["dataEncoding"]?.arrayValue
        else {
            throw BinaryCIFError.malformed("StringArray is missing a field")
        }

        let offsets = try applyChain(offsetEncoding, to: offsetBytes).map { Int($0) }
        // Index by UTF-8 offsets over an Array of Characters would be wrong for
        // any non-ASCII content; the offsets are byte offsets into the blob.
        let blob = Array(stringData.utf8)
        var pieces: [String] = []
        pieces.reserveCapacity(max(offsets.count - 1, 0))
        for index in 0..<max(offsets.count - 1, 0) {
            let start = offsets[index]
            let end = offsets[index + 1]
            guard start >= 0, end <= blob.count, start <= end else {
                throw BinaryCIFError.malformed("StringArray offsets out of range")
            }
            pieces.append(String(decoding: blob[start..<end], as: UTF8.self))
        }

        let indices = try applyChain(
            Array(remaining) + dataEncoding, to: data
        ).map { Int($0) }

        return indices.map { index in
            // -1 marks an absent value, which the mask also records.
            index >= 0 && index < pieces.count ? pieces[index] : ""
        }
    }

    /// Undo an encoding chain. The chain is written in the order it was applied,
    /// so it is undone from the END.
    static func applyChain(
        _ encodings: [MessagePackValue], to data: Data
    ) throws -> [Double] {
        guard let last = encodings.last else {
            throw BinaryCIFError.malformed("empty encoding chain")
        }
        var values = try decodeByteLevel(last, data: data)
        for encoding in encodings.dropLast().reversed() {
            values = try apply(encoding, to: values)
        }
        return values
    }

    private static func decodeByteLevel(
        _ encoding: MessagePackValue, data: Data
    ) throws -> [Double] {
        switch encoding["kind"]?.stringValue {
        case "ByteArray":
            return try byteArray(data, type: encoding["type"]?.intValue ?? 0)
        case "IntegerPacking":
            let byteCount = encoding["byteCount"]?.intValue ?? 1
            let isUnsigned = encoding["isUnsigned"]?.boolValue ?? false
            let srcSize = encoding["srcSize"]?.intValue ?? 0
            let packed = try byteArray(
                data, type: packedType(byteCount: byteCount, isUnsigned: isUnsigned))
            return unpack(packed, byteCount: byteCount, isUnsigned: isUnsigned, srcSize: srcSize)
        default:
            throw BinaryCIFError.unsupportedEncoding(
                "byte level \(encoding["kind"]?.stringValue ?? "unknown")")
        }
    }

    private static func apply(
        _ encoding: MessagePackValue, to values: [Double]
    ) throws -> [Double] {
        switch encoding["kind"]?.stringValue {
        case "FixedPoint":
            let factor = encoding["factor"]?.doubleValue ?? 1
            return values.map { $0 / factor }
        case "IntervalQuantization":
            let minimum = encoding["min"]?.doubleValue ?? 0
            let maximum = encoding["max"]?.doubleValue ?? 0
            let steps = encoding["numSteps"]?.intValue ?? 1
            let delta = steps > 1 ? (maximum - minimum) / Double(steps - 1) : 0
            return values.map { minimum + $0 * delta }
        case "RunLength":
            var output: [Double] = []
            output.reserveCapacity(encoding["srcSize"]?.intValue ?? values.count)
            var index = 0
            while index + 1 < values.count {
                let value = values[index]
                let count = Int(values[index + 1])
                guard count >= 0 else {
                    throw BinaryCIFError.malformed("negative run length")
                }
                output.append(contentsOf: repeatElement(value, count: count))
                index += 2
            }
            return output
        case "Delta":
            let origin = encoding["origin"]?.doubleValue ?? 0
            var running = origin
            return values.map { delta in
                running += delta
                return running
            }
        case "IntegerPacking":
            let byteCount = encoding["byteCount"]?.intValue ?? 1
            let isUnsigned = encoding["isUnsigned"]?.boolValue ?? false
            let srcSize = encoding["srcSize"]?.intValue ?? 0
            return unpack(
                values, byteCount: byteCount, isUnsigned: isUnsigned, srcSize: srcSize)
        case "ByteArray":
            return values
        default:
            throw BinaryCIFError.unsupportedEncoding(
                encoding["kind"]?.stringValue ?? "unknown")
        }
    }

    private static func packedType(byteCount: Int, isUnsigned: Bool) -> Int {
        switch (byteCount, isUnsigned) {
        case (1, true): 4
        case (1, false): 1
        case (2, true): 5
        case (2, false): 2
        default: isUnsigned ? 6 : 3
        }
    }

    /// Undo IntegerPacking.
    ///
    /// A value too large for the narrow type is written as the type's extreme
    /// and the remainder continues in the next element, possibly for several
    /// elements. Stopping at the first extreme, which is the obvious reading,
    /// truncates every large coordinate in the file.
    static func unpack(
        _ packed: [Double], byteCount: Int, isUnsigned: Bool, srcSize: Int
    ) -> [Double] {
        let limit: Double =
            isUnsigned
            ? (byteCount == 1 ? 0xFF : (byteCount == 2 ? 0xFFFF : 0xFFFF_FFFF))
            : (byteCount == 1 ? 0x7F : (byteCount == 2 ? 0x7FFF : 0x7FFF_FFFF))
        let lowerLimit = isUnsigned ? 0 : -limit - 1

        var output: [Double] = []
        output.reserveCapacity(srcSize > 0 ? srcSize : packed.count)
        var total: Double = 0
        for value in packed {
            if value == limit || (!isUnsigned && value == lowerLimit) {
                total += value
                continue
            }
            total += value
            output.append(total)
            total = 0
        }
        if total != 0 { output.append(total) }
        return output
    }

    private static func byteArray(_ data: Data, type: Int) throws -> [Double] {
        let bytes = [UInt8](data)
        func read<T: FixedWidthInteger>(_ width: Int, _ transform: (UInt64) -> T) -> [Double] {
            var values: [Double] = []
            values.reserveCapacity(bytes.count / width)
            var index = 0
            while index + width <= bytes.count {
                var raw: UInt64 = 0
                // Little endian, per the specification.
                for offset in (0..<width).reversed() {
                    raw = raw << 8 | UInt64(bytes[index + offset])
                }
                values.append(Double(transform(raw)))
                index += width
            }
            return values
        }

        switch type {
        case 1: return read(1) { Int8(bitPattern: UInt8(truncatingIfNeeded: $0)) }
        case 2: return read(2) { Int16(bitPattern: UInt16(truncatingIfNeeded: $0)) }
        case 3: return read(4) { Int32(bitPattern: UInt32(truncatingIfNeeded: $0)) }
        case 4: return read(1) { UInt8(truncatingIfNeeded: $0) }
        case 5: return read(2) { UInt16(truncatingIfNeeded: $0) }
        case 6: return read(4) { UInt32(truncatingIfNeeded: $0) }
        case 32:
            var values: [Double] = []
            var index = 0
            while index + 4 <= bytes.count {
                var raw: UInt32 = 0
                for offset in (0..<4).reversed() {
                    raw = raw << 8 | UInt32(bytes[index + offset])
                }
                values.append(Double(Float(bitPattern: raw)))
                index += 4
            }
            return values
        case 33:
            var values: [Double] = []
            var index = 0
            while index + 8 <= bytes.count {
                var raw: UInt64 = 0
                for offset in (0..<8).reversed() {
                    raw = raw << 8 | UInt64(bytes[index + offset])
                }
                values.append(Double(bitPattern: raw))
                index += 8
            }
            return values
        default:
            throw BinaryCIFError.unsupportedEncoding("ByteArray type \(type)")
        }
    }
}
