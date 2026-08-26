//  ScoringModelTests.swift
//  BoffinMLTests
//
//  The scoring model exists only to make the masked-marginal scan faster, so
//  the only thing that matters about it is that the scan's ANSWER does not
//  change. A batched path that is subtly wrong renders as a perfectly
//  plausible delta-LLR heat map, which this project has already been caught by
//  twice: once reading float32 storage as Float16, and once indexing a padded
//  logits array as though it were dense. Both produced convincing pictures in
//  which a quarter of substitutions beat the wild type of a highly conserved
//  protein, and neither errored.
//
//  So the test is a differential one: the same sequence, scored both ways,
//  compared element by element.

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

private var backboneURL: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.mlpackage")
}
private var scoringURL: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.scoring.mlpackage")
}
private var tokeniserURL: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.tokeniser.json")
}

private var modelsPresent: Bool {
    let manager = FileManager.default
    return manager.fileExists(atPath: backboneURL.path)
        && manager.fileExists(atPath: scoringURL.path)
}

/// CDK2, 298 residues, so 300 tokens: the bucket the scoring model is traced
/// at. A shorter protein would take the batch-1 path and prove nothing.
private func cdk2() throws -> ProteinSequence {
    let text = try String(
        contentsOf: repositoryRoot.appending(
            path: "Fixtures/sequences/P24941_CDK2_HUMAN.fasta"), encoding: .utf8)
    let letters = text.split(separator: "\n")
        .filter { !$0.hasPrefix(">") }
        .joined()
    return ProteinSequence(name: "CDK2", letters: letters, source: .pasted)
}

@Suite("Scoring model")
struct ScoringModelTests {

    @Test("CDK2 lands in the bucket the scoring model is traced at")
    func fixtureUsesTheBatchedPath() throws {
        let sequence = try cdk2()
        let tokens = 2 + sequence.count
        // Asserted, not assumed: if this fell into another bucket the
        // differential test below would compare batch 1 against batch 1 and
        // pass while testing nothing.
        #expect(
            ShapeBucket.smallestFitting(tokenCount: tokens)
                == EmbeddingEngine.scoringBucket)
    }

    // Thirty minutes, not ten. The cost is three model compilations rather
    // than the forty forward passes: an .mlpackage is compiled on load and
    // takes about fifty seconds each here. Alone this test runs in 146 s;
    // alongside the rest of the suite, competing for the same Neural Engine,
    // it took 869 and tripped a ten-minute limit while comparing the matrices
    // perfectly correctly. A time limit that fires under load is a flaky test
    // reporting itself as a correctness failure, which is the worst of both.
    @Test(
        "Batched scoring gives the same matrix as scoring a row at a time",
        .enabled(if: modelsPresent), .timeLimit(.minutes(30)))
    func batchedMatchesUnbatched() async throws {
        let sequence = try cdk2()
        // Twenty positions rather than all 298: enough to span several
        // batches, including a final partial one, which is where a fixed batch
        // padded up to eight rows would go wrong.
        let positions = Array(stride(from: 10, to: 210, by: 10))
        #expect(
            positions.count % EmbeddingEngine.scoringBatchSize != 0,
            "the last batch must be partial or the padding path is untested")

        let batched = try EmbeddingEngine(
            modelURL: backboneURL, tokeniserURL: tokeniserURL,
            scoringModelURL: scoringURL)
        let unbatched = try EmbeddingEngine(
            modelURL: backboneURL, tokeniserURL: tokeniserURL)

        let fast = try await batched.maskedMarginals(sequence, positions: positions)
        let slow = try await unbatched.maskedMarginals(sequence, positions: positions)

        #expect(fast.positions == slow.positions)
        #expect(fast.wildType == slow.wildType)
        #expect(fast.values.count == slow.values.count)

        var worst = 0.0
        for (a, b) in zip(fast.values, slow.values) {
            for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
        }
        let detail = String(format: "%.6f", worst)
        // Identical, not merely close: both paths run the same weights at the
        // same precision on the same device, so any difference is a bug rather
        // than arithmetic.
        #expect(worst < 1e-4, "worst element difference \(detail)")
    }
}
