//  HomologAlignment.swift
//  BoffinData
//
//  Composing a homolog hit with SIFTS, so a residue in the user's sequence can
//  be named the way a paper names it.
//
//  The chain is: query residue -> (alignment) -> SEQRES position of the hit ->
//  (SIFTS) -> PDB author number. Each hop can fail for a real reason, and each
//  reason is different information:
//
//  * the alignment can leave a query residue in a gap, meaning the hit has no
//    corresponding residue at all;
//  * SIFTS can have no segment covering that SEQRES position, meaning the
//    residue is in the construct but was not resolved;
//  * the covering segment can be non-arithmetic, meaning author numbering there
//    carries insertion codes and cannot be derived by offset.
//
//  All three are reported as themselves rather than collapsed into a missing
//  number, because "not observed in the crystal" is a fact a structural
//  biologist wants and "we could not work it out" is an apology.

import BoffinCore
import Foundation

/// Why a residue has no PDB author number.
public enum ResidueMappingFailure: Sendable, Hashable {
    /// The alignment puts this query residue opposite a gap.
    case notAligned
    /// Aligned, but SIFTS reports the position as unobserved in that chain.
    case notObserved
    /// Observed, but the covering segment carries insertion codes so the
    /// number cannot be derived arithmetically.
    case insertionCoded
}

public enum ResidueMapping: Sendable, Hashable {
    case mapped(author: Int, uniprot: Int)
    case unmapped(ResidueMappingFailure)

    public var authorNumber: Int? {
        if case .mapped(let author, _) = self { return author }
        return nil
    }
}

/// A homolog hit aligned to the query, with residue-level numbering.
public struct HomologAlignment: Sendable {
    public let hit: HomologHit

    /// True sequence identity from the alignment, over the hit's length.
    ///
    /// Reported alongside the embedding similarity and never instead of it.
    /// They are different measurements and they disagree in the interesting
    /// cases: two proteins with the same fold and 15% identity can sit high in
    /// embedding space, which is the entire reason this index is useful and
    /// also the reason a cosine must never be presented as a percentage.
    public let identity: Double

    /// Fraction of the query that aligned to the hit at all.
    public let coverage: Double

    private let queryToSeqres: [Int: Int]
    private let segments: [SIFTSSegment]

    public init(
        hit: HomologHit,
        query: [AminoAcid],
        reference: [AminoAcid],
        segments: [SIFTSSegment]
    ) {
        self.hit = hit
        let alignment = SequenceAlignment.align(query: query, reference: reference)
        self.identity = alignment.identity(query: query, reference: reference)

        var map: [Int: Int] = [:]
        for column in alignment.columns {
            // SIFTS SEQRES positions are one-based.
            if case .match(let q, let r) = column { map[q] = r + 1 }
        }
        self.queryToSeqres = map
        self.coverage = query.isEmpty ? 0 : Double(map.count) / Double(query.count)
        self.segments = segments.filter { $0.pdb == hit.pdb && $0.chain == hit.chain }
    }

    /// Where a zero-based query residue lands in the hit's structure.
    public func mapping(forQueryResidue index: Int) -> ResidueMapping {
        guard let seqres = queryToSeqres[index] else { return .unmapped(.notAligned) }
        guard let segment = segments.first(where: { $0.seqresStart...$0.seqresEnd ~= seqres })
        else { return .unmapped(.notObserved) }
        guard
            let author = segment.authorNumber(forSeqres: seqres),
            let uniprot = segment.uniprotNumber(forSeqres: seqres)
        else { return .unmapped(.insertionCoded) }
        return .mapped(author: author, uniprot: uniprot)
    }

    /// The mapping as a categorical track on the shared ruler, so PDB numbering
    /// stacks with every other annotation rather than living in its own table.
    public func track(residueCount: Int) -> AnyResidueTrack {
        var labels = [String?](repeating: nil, count: residueCount)
        for index in 0..<residueCount {
            if case .mapped(let author, _) = mapping(forQueryResidue: index) {
                labels[index] = String(author)
            }
        }
        return AnyResidueTrack(
            id: TrackID("pdb-numbering"),
            title: "\(hit.pdb)_\(hit.chain) author numbering, "
                + "\(Int(identity * 100))% identity",
            kind: .categorical,
            values: .categorical(labels),
            colourScheme: .categorical)
    }
}
