//  ResidueTrack.swift
//  BoffinCore
//
//  Invariant 2 of the build plan: everything is a ResidueTrack.
//
//  Disorder, secondary structure, TM spans, delta-LLR, motifs and
//  structure-derived interactions are all arrays aligned one-to-one with the
//  sequence, stacked on a single ruler. Tabs are filters over that ruler, not
//  separate features. Any feature that cannot be expressed as a ResidueTrack or
//  a structure overlay needs an explicit design decision first.

/// A stable identifier for a track, so tracks can be reordered, pinned and
/// persisted without depending on their position in an array.
public struct TrackID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// How a track is drawn on the ruler.
public enum TrackKind: Sendable, Hashable, Codable {
    /// One scalar per residue, drawn as a filled area or line (disorder, pLDDT).
    case continuous
    /// One label per residue, drawn as coloured blocks (SS3, SS8).
    case categorical
    /// Contiguous ranges, drawn as bars (TM helices, domains, motifs).
    case span
    /// One vector per residue, drawn as a heatmap column (delta-LLR).
    case matrix
}

/// Track payloads. The count of every case is asserted equal to the residue
/// count by `validate(against:)`: a track that silently misaligns with its
/// sequence is a correctness bug that surfaces as a plausible-looking picture.
public enum TrackValues: Sendable, Hashable {
    case continuous([Double?])
    case categorical([String?])
    case spans([TrackSpan])
    case matrix(rows: [String], columns: [[Double?]])

    /// Number of residues this payload covers, or `nil` for spans, which are
    /// validated by their bounds instead.
    public var alignedCount: Int? {
        switch self {
        case .continuous(let values): values.count
        case .categorical(let values): values.count
        case .matrix(_, let columns): columns.count
        case .spans: nil
        }
    }
}

/// A contiguous, inclusive range of residue indices with a label.
public struct TrackSpan: Sendable, Hashable, Codable {
    public let start: Int
    public let end: Int
    public let label: String

    public init(start: Int, end: Int, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }

    public var range: ClosedRange<Int> { start...end }
}

/// How a track maps values to colour. Concrete palettes live in BoffinUI: this
/// is the semantic choice, not the hex codes, so BoffinCore stays free of UI.
public enum TrackColourScheme: Sendable, Hashable, Codable {
    /// Sequential, for bounded continuous values such as a probability.
    case sequential(min: Double, max: Double)
    /// Diverging about a midpoint, for signed values such as delta-LLR.
    case diverging(min: Double, mid: Double, max: Double)
    /// A fixed categorical set, keyed by category label.
    case categorical
    /// A single accent colour, for spans and motifs.
    case solid
}

/// Invariant 2. Every analytical output in BOFFIN conforms to this.
public protocol ResidueTrack: Sendable {
    var id: TrackID { get }
    var title: String { get }
    var kind: TrackKind { get }
    var values: TrackValues { get }
    var colourScheme: TrackColourScheme { get }
}

extension ResidueTrack {
    /// Check that this track lines up with the sequence it claims to describe.
    ///
    /// Call this at every boundary where a track is produced. A misaligned
    /// track does not crash: it draws a convincing picture of the wrong thing.
    public func validate(against sequence: ProteinSequence) throws(TrackAlignmentError) {
        let residueCount = sequence.count

        if let alignedCount = values.alignedCount, alignedCount != residueCount {
            throw TrackAlignmentError.countMismatch(
                track: id, expected: residueCount, found: alignedCount)
        }

        if case .spans(let spans) = values {
            for span in spans
            where span.start < 0 || span.end >= residueCount || span.start > span.end {
                throw TrackAlignmentError.spanOutOfBounds(
                    track: id, span: span, residueCount: residueCount)
            }
        }

        if case .matrix(let rows, let columns) = values {
            for column in columns where column.count != rows.count {
                throw TrackAlignmentError.matrixRaggedColumn(
                    track: id, expectedRows: rows.count, found: column.count)
            }
        }
    }
}

public enum TrackAlignmentError: Error, Sendable, Hashable {
    case countMismatch(track: TrackID, expected: Int, found: Int)
    case spanOutOfBounds(track: TrackID, span: TrackSpan, residueCount: Int)
    case matrixRaggedColumn(track: TrackID, expectedRows: Int, found: Int)
}

/// A ready-made concrete track, for producers that have no behaviour to add.
public struct AnyResidueTrack: ResidueTrack, Hashable {
    public let id: TrackID
    public let title: String
    public let kind: TrackKind
    public let values: TrackValues
    public let colourScheme: TrackColourScheme

    public init(
        id: TrackID,
        title: String,
        kind: TrackKind,
        values: TrackValues,
        colourScheme: TrackColourScheme
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.values = values
        self.colourScheme = colourScheme
    }
}
