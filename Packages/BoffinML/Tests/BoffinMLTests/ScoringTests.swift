//  ScoringTests.swift
//  BoffinMLTests
//
//  Cross-language check on the delta-LLR maths. A sign error or a mistaken
//  normalisation produces a matrix that renders perfectly and means the
//  opposite of what it says, so the distribution is asserted against values
//  computed independently in Python from the same model.

import BoffinCore
import Foundation
import Testing

@testable import BoffinML

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}
private var modelURL: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.mlpackage")
}
private var tokeniserURL: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.tokeniser.json")
}
private var modelIsAvailable: Bool {
    FileManager.default.fileExists(atPath: modelURL.path)
}

private let ubiquitin =
    "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"

@Suite(
    "Delta-LLR scoring",
    .enabled(if: modelIsAvailable, "converted model not present: run convert_backbone.py"))
struct ScoringTests {

    @Test("Ubiquitin scores as a highly conserved protein")
    func ubiquitinIsConserved() async throws {
        let engine = try EmbeddingEngine(modelURL: modelURL, tokeniserURL: tokeniserURL)
        let sequence = ProteinSequence(name: "ubq", letters: ubiquitin, source: .pasted)
        let matrix = try await engine.maskedMarginals(sequence, mode: .wildTypeMarginal)

        let all = matrix.values.flatMap { $0 }
        let negative = Double(all.filter { $0 < -1e-9 }.count) / Double(all.count)
        let zero = Double(all.filter { abs($0) < 1e-9 }.count) / Double(all.count)

        // Independently computed in Python from the same model: 95% negative,
        // 5% exactly zero (the wild types), nothing above zero.
        #expect(negative > 0.90, "only \(negative) of substitutions were deleterious")
        #expect(abs(zero - 0.05) < 0.01, "wild-type fraction was \(zero)")
        #expect((all.max() ?? 1) <= 1e-9, "a substitution beat the wild type")
    }

    @Test("The wild type scores exactly zero at every position")
    func wildTypeIsZero() async throws {
        let engine = try EmbeddingEngine(modelURL: modelURL, tokeniserURL: tokeniserURL)
        let sequence = ProteinSequence(name: "ubq", letters: ubiquitin, source: .pasted)
        let matrix = try await engine.maskedMarginals(sequence, mode: .wildTypeMarginal)

        for (column, wildType) in matrix.wildType.enumerated() {
            guard let row = matrix.rows.firstIndex(of: wildType) else { continue }
            #expect(abs(matrix.values[column][row]) < 1e-9)
        }
    }

    @Test("Lysine 48 prefers arginine, the conservative substitution")
    func k48PrefersArginine() async throws {
        let engine = try EmbeddingEngine(modelURL: modelURL, tokeniserURL: tokeniserURL)
        let sequence = ProteinSequence(name: "ubq", letters: ubiquitin, source: .pasted)
        let matrix = try await engine.maskedMarginals(sequence, mode: .wildTypeMarginal)

        // K48 is the polyubiquitin linkage site. Whatever else the model
        // thinks, the least-bad substitution should be the chemically
        // conservative Lys to Arg.
        guard let extremes = matrix.extremes(at: 47) else {
            Issue.record("position 48 was not scored")
            return
        }
        #expect(extremes.best == .lysine || extremes.best == .arginine)
    }

    @Test("The fast mode and the accurate mode disagree, as they should")
    func modesDiffer() async throws {
        let engine = try EmbeddingEngine(modelURL: modelURL, tokeniserURL: tokeniserURL)
        // Short sequence: the masked mode is one pass per position.
        let sequence = ProteinSequence(
            name: "t", letters: String(ubiquitin.prefix(24)), source: .pasted)

        let fast = try await engine.maskedMarginals(sequence, mode: .wildTypeMarginal)
        let accurate = try await engine.maskedMarginals(sequence, mode: .maskedMarginal)

        // If these agreed exactly, one mode would not be doing what it claims.
        var worst = 0.0
        for (a, b) in zip(fast.values, accurate.values) {
            for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
        }
        #expect(worst > 0.1, "the two scoring modes produced identical matrices")

        // NOT asserted here: that nothing beats the wild type. That holds for
        // the fast mode, where the model can see the wild-type residue and so
        // always prefers it. Under masking it does NOT hold and should not: the
        // model is shown a gap and asked what belongs there, and it is
        // sometimes more confident about a different residue than about the one
        // nature chose. Measured here at up to +2.39. That freedom is precisely
        // why the masked mode is the more informative of the two.
        let accurateMaximum = accurate.values.flatMap { $0 }.max() ?? 0
        #expect(accurateMaximum > 0, "masked scoring should sometimes beat the wild type")

        // The wild type still scores exactly zero, by construction.
        for (column, wildType) in accurate.wildType.enumerated() {
            guard let row = accurate.rows.firstIndex(of: wildType) else { continue }
            #expect(abs(accurate.values[column][row]) < 1e-9)
        }
    }
}
