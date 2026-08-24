//  Sequence.swift
//  BoffinCore

import struct Foundation.UUID

/// A protein sequence and its provenance.
///
/// Named `ProteinSequence` rather than `Sequence` to avoid shadowing the
/// standard library protocol, which would make every generic constraint in the
/// package ambiguous.
public struct ProteinSequence: Sendable, Hashable, Codable, Identifiable {
    public let id: SequenceID
    public let name: String
    public let residues: [Residue]
    public let source: SequenceSource

    public var count: Int { residues.count }

    /// The one-letter string, as the model tokeniser sees it.
    public var letters: String { String(residues.map(\.code)) }

    public init(
        id: SequenceID = SequenceID(),
        name: String,
        residues: [Residue],
        source: SequenceSource
    ) {
        self.id = id
        self.name = name
        self.residues = residues
        self.source = source
    }

    /// Build from a one-letter string, assigning zero-based indices.
    /// Whitespace and digits (as found in pasted alignments and GenBank-style
    /// blocks) are stripped. Any other character is preserved as
    /// non-canonical rather than dropped.
    public init(name: String, letters: String, source: SequenceSource) {
        let kept = letters.filter { !$0.isWhitespace && !$0.isNumber }
        let residues = kept.enumerated().map { offset, character in
            Residue(index: offset, identity: ResidueIdentity(code: character))
        }
        self.init(name: name, residues: residues, source: source)
    }
}

public struct SequenceID: Sendable, Hashable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

/// Where a sequence came from. Recorded because the Family and Boundary tabs
/// treat a UniProt entry (with a known accession and features) differently from
/// an anonymous pasted string.
public enum SequenceSource: Sendable, Hashable, Codable {
    case pasted
    case fasta(fileName: String)
    case uniProt(accession: String)
    case pdbSeqRes(entryID: String, chainID: String)
    case fixture(name: String)
}
