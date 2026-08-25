//  SIFTSStore.swift
//  BoffinData
//
//  SIFTS residue-level correspondence between UniProt, PDB SEQRES and PDB
//  AUTHOR numbering.
//
//  Why this cannot be arithmetic on its own
//  ----------------------------------------
//  PDB author numbering is whatever the depositor chose. It is frequently not
//  1-based, not contiguous, occasionally negative (expression tags are often
//  numbered backwards from the start of the construct), and carries insertion
//  codes where a numbering scheme is being preserved across homologues. So the
//  residue a paper calls "Asp145" is not the 145th residue of anything BOFFIN
//  computes, and guessing the offset from the first observed residue is wrong
//  the moment a loop is disordered.
//
//  SIFTS resolves this properly, by curated alignment, and publishes it per
//  segment: a contiguous run in which all three coordinate systems advance
//  together. Inside a segment the mapping is an offset. BETWEEN segments there
//  is no mapping at all, because the residues in between were not observed, and
//  interpolating across that gap is exactly how a residue number ends up
//  plausible and wrong.
//
//  1.87% of the segments here are marked non-arithmetic, either because the
//  author numbering carries an insertion code or because the three coordinate
//  systems do not advance by equal amounts. Those are refused rather than
//  approximated.

import BoffinCore
import Foundation

/// A contiguous run of residues with a fixed offset between the three
/// coordinate systems.
public struct SIFTSSegment: Sendable, Hashable {
    public let pdb: String
    public let chain: String
    /// One-based SEQRES positions covered, inclusive.
    public let seqresStart: Int
    public let seqresEnd: Int
    /// UniProt residue number of `seqresStart`.
    public let uniprotStart: Int
    /// PDB author residue number of `seqresStart`.
    public let authorStart: Int
    /// Whether the three systems advance together across the whole segment.
    /// When false, no number is derivable from this segment.
    public let isArithmetic: Bool

    public var length: Int { seqresEnd - seqresStart + 1 }
    public var uniprotRange: ClosedRange<Int> {
        uniprotStart...(uniprotStart + length - 1)
    }
    public var authorRange: ClosedRange<Int>? {
        isArithmetic ? authorStart...(authorStart + length - 1) : nil
    }

    /// PDB author number for a one-based SEQRES position, or `nil` if that
    /// position lies outside this segment or the segment is not arithmetic.
    public func authorNumber(forSeqres position: Int) -> Int? {
        guard isArithmetic, seqresStart...seqresEnd ~= position else { return nil }
        return authorStart + (position - seqresStart)
    }

    /// PDB author number for a UniProt residue number.
    public func authorNumber(forUniProt number: Int) -> Int? {
        guard isArithmetic, uniprotRange ~= number else { return nil }
        return authorStart + (number - uniprotStart)
    }

    /// UniProt residue number for a one-based SEQRES position.
    ///
    /// Available even when the segment is not arithmetic in AUTHOR numbering,
    /// because it is the author numbering that carries the insertion codes.
    public func uniprotNumber(forSeqres position: Int) -> Int? {
        guard seqresStart...seqresEnd ~= position else { return nil }
        return uniprotStart + (position - seqresStart)
    }
}

/// Every observed construct deposited for one UniProt accession.
///
/// This is the crystallisation precedent the Boundary tab is built on: not what
/// the sequence suggests, but which spans people actually got to order.
public struct ObservedConstruct: Sendable, Hashable, Identifiable {
    public let pdb: String
    public let chain: String
    /// Observed UniProt spans, ascending, with the gaps between them being
    /// residues that were present in the crystal and not visible in the map.
    public let spans: [ClosedRange<Int>]

    public var id: String { "\(pdb)_\(chain)" }
    public var first: Int { spans.first?.lowerBound ?? 0 }
    public var last: Int { spans.last?.upperBound ?? 0 }
    public var observedCount: Int { spans.reduce(0) { $0 + $1.count } }
    /// Residues inside the observed extent that were not resolved.
    public var disorderedCount: Int { (last - first + 1) - observedCount }
}

public enum SIFTSStoreError: Error, Sendable {
    case unavailable(String)
    case malformed(String)
}

/// The bundled SIFTS segment table.
public struct SIFTSStore: Sendable {

    private static let accessionRecordSize = 16
    private static let segmentRecordSize = 28

    private let data: Data
    public let accessionCount: Int
    public let segmentCount: Int
    private let namesOffset: Int
    private let segmentsOffset: Int

    public init(url: URL) throws {
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SIFTSStoreError.unavailable(error.localizedDescription)
        }
        guard data.count >= 24, data.prefix(8).elementsEqual("BOFSIFT1".utf8) else {
            throw SIFTSStoreError.malformed("not a BOFSIFT1 file")
        }
        accessionCount = Int(data.readUInt32(at: 8))
        segmentCount = Int(data.readUInt32(at: 12))
        namesOffset = Int(data.readUInt32(at: 16))
        segmentsOffset = Int(data.readUInt32(at: 20))
        guard
            segmentsOffset + segmentCount * Self.segmentRecordSize <= data.count
        else {
            throw SIFTSStoreError.malformed("file is shorter than its header claims")
        }
    }

    /// Segments for an accession, in file order.
    ///
    /// Accession names are stored sorted, so this is a binary search rather
    /// than a dictionary: building a 72,000-entry dictionary at launch would
    /// cost more than every lookup the app will ever perform.
    public func segments(for accession: String) -> [SIFTSSegment] {
        guard let record = find(accession) else { return [] }
        let first = Int(data.readUInt32(at: record + 8))
        let count = Int(data.readUInt32(at: record + 12))
        return (0..<count).compactMap { segment(at: first + $0) }
    }

    /// Every deposited construct for an accession, most complete first.
    public func constructs(for accession: String) -> [ObservedConstruct] {
        var grouped: [String: [ClosedRange<Int>]] = [:]
        for segment in segments(for: accession) {
            grouped["\(segment.pdb)\t\(segment.chain)", default: []].append(segment.uniprotRange)
        }
        return grouped.map { key, spans in
            let parts = key.split(separator: "\t", omittingEmptySubsequences: false)
            return ObservedConstruct(
                pdb: String(parts[0]),
                chain: parts.count > 1 ? String(parts[1]) : "",
                spans: merge(spans))
        }
        .sorted {
            ($0.observedCount, $0.pdb) > ($1.observedCount, $1.pdb)
        }
    }

    /// PDB author number for a UniProt residue number, in a named entry.
    ///
    /// - Returns: `nil` when the residue was not observed in that chain, or
    ///   when the covering segment is not arithmetic. Both are real answers and
    ///   neither is an approximation.
    public func authorNumber(
        forUniProt number: Int, pdb: String, chain: String, accession: String
    ) -> Int? {
        for segment in segments(for: accession)
        where segment.pdb == pdb && segment.chain == chain {
            if let author = segment.authorNumber(forUniProt: number) { return author }
        }
        return nil
    }

    // MARK: - Internals

    /// Merge overlapping and touching spans. SIFTS can report the same residues
    /// in more than one segment for a chain, and counting them twice would
    /// overstate how much of a construct ordered.
    private func merge(_ spans: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for span in sorted {
            if let last = merged.last, span.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func find(_ accession: String) -> Int? {
        var low = 0
        var high = accessionCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let record = 24 + middle * Self.accessionRecordSize
            let name = self.name(at: record)
            if name == accession { return record }
            if name < accession { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    private func name(at record: Int) -> String {
        let offset = namesOffset + Int(data.readUInt32(at: record))
        let length = Int(data.readUInt16(at: record + 4))
        guard offset + length <= data.count else { return "" }
        let start = data.startIndex + offset
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    private func segment(at index: Int) -> SIFTSSegment? {
        guard index >= 0, index < segmentCount else { return nil }
        let base = segmentsOffset + index * Self.segmentRecordSize
        return SIFTSSegment(
            pdb: ascii(at: base, length: 4),
            chain: ascii(at: base + 4, length: 4),
            seqresStart: Int(data.readInt32(at: base + 8)),
            seqresEnd: Int(data.readInt32(at: base + 12)),
            uniprotStart: Int(data.readInt32(at: base + 16)),
            authorStart: Int(data.readInt32(at: base + 20)),
            isArithmetic: data[data.startIndex + base + 24] == 1)
    }

    /// Fixed-width ASCII field, NUL-padded.
    private func ascii(at offset: Int, length: Int) -> String {
        var characters: [UInt8] = []
        for index in 0..<length {
            let byte = data[data.startIndex + offset + index]
            if byte == 0 { break }
            characters.append(byte)
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
