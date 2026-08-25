//  AlignmentTests.swift
//  BoffinCoreTests
//
//  An aligner that is subtly wrong produces a numbering that is subtly wrong,
//  and a residue number off by two is invisible to everyone who reads it. These
//  check the properties that matter rather than one hand-checked example.

import Foundation
import Testing

@testable import BoffinCore

private func acids(_ letters: String) -> [AminoAcid] {
    letters.compactMap { AminoAcid(rawValue: $0) }
}

@Suite("BLOSUM62")
struct BlosumTests {

    @Test("The matrix covers all 400 canonical pairs")
    func matrixIsComplete() {
        var total = 0
        for a in AminoAcid.canonical {
            for b in AminoAcid.canonical {
                #expect(AminoAcidTables.blosum62[a]?[b] != nil, "missing \(a.code)/\(b.code)")
                total += 1
            }
        }
        #expect(total == 400)
    }

    @Test("Known BLOSUM62 values are correct")
    func knownValues() {
        // Straight from the published matrix. Tryptophan against itself is the
        // highest diagonal at 11; W against D is one of the worst at -4.
        #expect(SequenceAlignment.score(.tryptophan, .tryptophan) == 11)
        #expect(SequenceAlignment.score(.cysteine, .cysteine) == 9)
        #expect(SequenceAlignment.score(.leucine, .isoleucine) == 2)
        #expect(SequenceAlignment.score(.tryptophan, .asparticAcid) == -4)
    }

    @Test("The matrix is symmetric")
    func matrixIsSymmetric() {
        for a in AminoAcid.canonical {
            for b in AminoAcid.canonical {
                #expect(
                    SequenceAlignment.score(a, b) == SequenceAlignment.score(b, a),
                    "\(a.code)/\(b.code) is asymmetric")
            }
        }
    }

    @Test("Conservative substitutions score above radical ones")
    func chemistryIsRespected() {
        // Leu/Ile are both branched aliphatics; Leu/Asp is hydrophobic against
        // charged. If this ever inverted, every alignment would be wrong in a
        // way that still produced alignments.
        #expect(
            SequenceAlignment.score(.leucine, .isoleucine)
                > SequenceAlignment.score(.leucine, .asparticAcid))
        #expect(
            SequenceAlignment.score(.lysine, .arginine)
                > SequenceAlignment.score(.lysine, .phenylalanine))
    }
}

@Suite("Pairwise alignment")
struct AlignmentTests {

    @Test("A sequence aligns to itself position for position")
    func identityAlignment() {
        let sequence = acids("MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDK")
        let alignment = SequenceAlignment.align(query: sequence, reference: sequence)
        let map = alignment.queryIndexByReference()

        #expect(map.count == sequence.count)
        for index in sequence.indices {
            #expect(map[index] == index, "position \(index) did not map to itself")
        }
        #expect(alignment.identity(query: sequence, reference: sequence) == 1.0)
    }

    @Test("An insertion shifts the mapping by exactly its length")
    func insertionShiftsMapping() {
        // The property the numbering depends on: everything after an insertion
        // must move by the insertion's length, and nothing before it may move.
        let reference = acids("MQIFVKTLTGKTITLEVEPSD")
        let query = acids("MQIFVKTLTG" + "WWWWW" + "KTITLEVEPSD")
        let map = SequenceAlignment.align(query: query, reference: reference)
            .queryIndexByReference()

        #expect(map[0] == 0, "the N-terminus should not move")
        #expect(map[9] == 9, "residues before the insertion should not move")
        #expect(map[10] == 15, "residues after a 5-residue insertion should shift by 5")
        #expect(map[20] == 25)
    }

    @Test("A deletion shifts the mapping the other way")
    func deletionShiftsMapping() {
        let reference = acids("MQIFVKTLTGWWWWWKTITLEVEPSD")
        let query = acids("MQIFVKTLTGKTITLEVEPSD")
        let map = SequenceAlignment.align(query: query, reference: reference)
            .queryIndexByReference()

        #expect(map[0] == 0)
        #expect(map[9] == 9)
        // Reference positions 10 to 14 are deleted in the query, so they map
        // nowhere at all rather than to a neighbour.
        for deleted in 10...14 { #expect(map[deleted] == nil) }
        #expect(map[15] == 10)
    }

    @Test("Affine gaps prefer one long gap to several short ones")
    func affineGapsPreferOneIndel() {
        // With a linear penalty an aligner scatters small gaps, which on a
        // kinase would scatter the pocket positions across loop insertions.
        let reference = acids("MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDK")
        var inserted = Array(reference[0..<16])
        inserted.append(contentsOf: acids("GGGGGGGG"))
        inserted.append(contentsOf: reference[16...])

        let alignment = SequenceAlignment.align(query: inserted, reference: reference)
        let runs = gapRuns(alignment)
        #expect(runs.count <= 2, "expected one insertion, got \(runs.count) gap runs")
    }

    @Test("Identity is reported so a weak alignment cannot pose as numbering")
    func identityIsReported() {
        let a = acids("MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDK")
        let b = acids("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW")
        let alignment = SequenceAlignment.align(query: a, reference: b)
        #expect(alignment.identity(query: a, reference: b) < 0.1)
    }

    @Test("Empty input yields an empty alignment rather than a crash")
    func emptyInput() {
        #expect(SequenceAlignment.align(query: [], reference: acids("MKV")).columns.isEmpty)
        #expect(SequenceAlignment.align(query: acids("MKV"), reference: []).columns.isEmpty)
    }

    @Test("Every mapped index is inside both sequences")
    func indicesAreInBounds() {
        let query = acids("MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQ")
        let reference = acids("MQIFVKTLTGWWKTITLEVEPSDTIENVKAKIQ")
        let map = SequenceAlignment.align(query: query, reference: reference)
            .queryIndexByReference()
        for (reference_, query_) in map {
            #expect(reference_ >= 0 && reference_ < reference.count)
            #expect(query_ >= 0 && query_ < query.count)
        }
    }

    private func gapRuns(_ alignment: Alignment) -> [Int] {
        var runs: [Int] = []
        var current = 0
        for column in alignment.columns {
            switch column {
            case .match:
                if current > 0 { runs.append(current) }
                current = 0
            case .queryGap, .referenceGap:
                current += 1
            }
        }
        if current > 0 { runs.append(current) }
        return runs
    }
}
