//  SequenceAlignmentTests.swift
//  BoffinCoreTests
//
//  The size bound on Gotoh's algorithm, and a check that flattening its score
//  matrices did not change any answer.

import Testing

@testable import BoffinCore

@Suite("Alignment size bound")
struct AlignmentBoundTests {

    private func residues(_ count: Int, _ code: Character) -> [AminoAcid] {
        Array(repeating: AminoAcid(rawValue: code) ?? .alanine, count: count)
    }

    /// Gotoh is O(n*m) in memory as well as time. Three score matrices for a
    /// 2,500-by-2,500 alignment are 150 MB even at Int32, and homolog search can
    /// return entries that long, so an unbounded aligner would allocate more
    /// than the app's whole budget while a user waited for a hit list.
    @Test("An alignment larger than the bound returns nothing, not a guess")
    func refusesOversizedAlignments() {
        let cells = SequenceAlignment.maximumCells
        let side = Int(Double(cells).squareRoot()) + 100
        let alignment = SequenceAlignment.align(
            query: residues(side, "A"), reference: residues(side, "A"))
        // Empty, so a caller reads "no correspondence" rather than a truncated
        // or approximated one that looks like a real result.
        #expect(alignment.columns.isEmpty)
        #expect(alignment.score == 0)
        #expect(alignment.identity(query: residues(side, "A"), reference: residues(side, "A")) == 0)
    }

    @Test("An alignment just inside the bound still runs")
    func acceptsLargeButBoundedAlignments() {
        // 1,000 by 1,000 is a million cells: an ordinary long protein against
        // another, and well inside the bound.
        let query = residues(1000, "A")
        let reference = residues(1000, "A")
        let alignment = SequenceAlignment.align(query: query, reference: reference)
        #expect(alignment.columns.count == 1000)
        #expect(alignment.identity(query: query, reference: reference) == 1.0)
    }

    @Test("The flat matrices give the same answer the nested ones did")
    func flatteningDidNotChangeTheResult() {
        // A case with a real indel, so the traceback exercises both gap states.
        let query = "ACDEFGHIKLMNPQRSTVWY".compactMap { AminoAcid(rawValue: $0) }
        let reference = "ACDEFGHIKLPQRSTVWY".compactMap { AminoAcid(rawValue: $0) }
        let alignment = SequenceAlignment.align(query: query, reference: reference)
        #expect(alignment.identity(query: query, reference: reference) == 1.0)
        #expect(alignment.columns.count == 20)
        let gaps = alignment.columns.filter {
            if case .queryGap = $0 { return true }
            return false
        }
        #expect(gaps.count == 2)
    }
}
