//  LLRMatrixTests.swift
//  BoffinCoreTests

import Foundation
import Testing

@testable import BoffinCore

private func matrix() -> LLRMatrix {
    // Three positions, twenty rows. Wild type scores 0 by definition, since
    // log P(wt) - log P(wt) is zero.
    let rows = AminoAcid.canonical
    let wild: [AminoAcid] = [.methionine, .lysine, .valine]
    var values: [[Double]] = []
    for (column, wt) in wild.enumerated() {
        var scores = [Double](repeating: -Double(column + 1), count: rows.count)
        if let index = rows.firstIndex(of: wt) { scores[index] = 0 }
        values.append(scores)
    }
    return LLRMatrix(positions: [0, 1, 2], wildType: wild, values: values)
}

@Suite("Delta-LLR matrix")
struct LLRMatrixTests {

    @Test("Row order is the canonical alphabet and does not drift")
    func rowOrderIsStable() {
        // Every cached matrix and exported CSV depends on this. A reordering
        // would silently transpose meaning rather than fail.
        #expect(matrix().rows == AminoAcid.canonical)
        #expect(String(matrix().rows.map(\.code)) == "ACDEFGHIKLMNPQRSTVWY")
    }

    @Test("The wild type scores zero by definition")
    func wildTypeScoresZero() {
        #expect(matrix().score(at: 0, to: .methionine) == 0)
        #expect(matrix().score(at: 1, to: .lysine) == 0)
    }

    @Test("An unscored position returns nil, not zero")
    func unscoredPositionIsNil() {
        // Zero is a real delta-LLR meaning "no preference". Returning it for
        // "not measured" would report an unscored site as perfectly tolerant.
        #expect(matrix().score(at: 99, to: .alanine) == nil)
    }

    @Test("The colour bound is symmetric about zero")
    func boundIsSymmetric() {
        // An asymmetric diverging scale puts zero off-centre, making tolerated
        // and deleterious substitutions look like different magnitudes.
        #expect(matrix().symmetricBound == 3)
    }

    @Test("Extremes identify the best and worst substitution at a position")
    func extremesAreFound() {
        let extremes = matrix().extremes(at: 1)
        #expect(extremes?.best == .lysine)
    }

    @Test("The track leaves unscored residues nil rather than zero")
    func trackLeavesGapsNil() throws {
        let track = matrix().track(residueCount: 6)
        guard case .matrix(let rows, let columns) = track.values else {
            Issue.record("expected a matrix track")
            return
        }
        #expect(rows.count == 20)
        #expect(columns.count == 6)
        #expect(columns[0].allSatisfy { $0 != nil })
        #expect(columns[5].allSatisfy { $0 == nil }, "unscored column should be nil")
    }

    @Test("The track validates against its sequence")
    func trackValidates() throws {
        let sequence = ProteinSequence(name: "t", letters: "MKVLAG", source: .pasted)
        try matrix().track(residueCount: sequence.count).validate(against: sequence)
    }

    @Test("CSV export uses one-based positions")
    func csvIsOneBased() {
        // Zero-based indices would be internally consistent and wrong in every
        // paper, tool and email the file is pasted into.
        let csv = matrix().commaSeparatedValues()
        let header = csv.split(separator: "\n").first ?? ""
        #expect(header.contains("M1"))
        #expect(header.contains("K2"))
        #expect(!header.contains("M0"))
    }

    @Test("CSV has one row per canonical residue plus a header")
    func csvShape() {
        let lines = matrix().commaSeparatedValues().split(separator: "\n")
        #expect(lines.count == 21)
    }

    @Test("Mutation labels use conventional one-based notation")
    func mutationLabels() {
        let mutation = Mutation(
            position: 47, wildType: .lysine, substitution: .arginine, score: -1.5)
        #expect(mutation.label == "K48R")
    }

    @Test("Mean per position summarises site constraint")
    func meanPerPosition() {
        let means = matrix().meanPerPosition
        #expect(means.count == 3)
        #expect(means[0] > means[2], "later positions were given more negative scores")
    }
}
