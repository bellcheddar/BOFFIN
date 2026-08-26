//  MaskedMarginalScorer.swift
//  BoffinML
//
//  Variant fitness by masked marginals (build plan section 4.4):
//
//      ΔLLR(i, mt) = log P(mt | x_masked(i)) − log P(wt | x_masked(i))
//
//  For each position the residue is replaced with `<mask>`, the model is run,
//  and the log-softmax over the twenty canonical amino acids is read at that
//  position. This is the fan-out from the same backbone that produces the Order
//  tab's tracks: invariant 1, one model, different read-outs.
//
//  Hard rule 5: never loop one Core ML prediction per residue. Masked positions
//  are batched. Measured on an M1 Max at bucket 384: 31.2 ms per variant
//  unbatched against 21.6 ms at batch 8, so batching is worth 31%. It saturates
//  at 8 (batch 16 was slightly worse), which matches the backbone being
//  compute-bound rather than memory-bound.

import BoffinCore
import CoreML
import Foundation

/// How the substitution scores are computed.
///
/// Both produce a delta-LLR matrix of the same shape and both are legitimate:
/// they differ in what they condition on, and therefore in cost and accuracy.
/// The mode is recorded on the result and shown in the UI, because two matrices
/// computed differently are not interchangeable and a reader cannot tell them
/// apart by looking.
public enum ScoringMode: String, CaseIterable, Sendable, Codable, Identifiable {

    /// Mask each position in turn and read the model's distribution there.
    ///
    /// One forward pass per position. This is the method the build plan
    /// specifies and the one to quote: the model is not shown the wild-type
    /// residue it is being asked about, so its distribution is a genuine
    /// prediction rather than a reconstruction.
    case maskedMarginal

    /// One forward pass over the unmasked sequence, reading the logits at every
    /// position.
    ///
    /// Roughly 200 times cheaper (a single pass rather than one per residue),
    /// and modestly less accurate: the model can see the wild-type residue at
    /// the position being scored, so it is partly reading rather than
    /// predicting. Documented in the ESM variant-effect literature as the cheap
    /// alternative, and useful as a live preview while the accurate scan runs.
    case wildTypeMarginal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maskedMarginal: "Masked marginal"
        case .wildTypeMarginal: "Fast preview"
        }
    }

    /// Shown next to the result, so a number is never presented without saying
    /// how it was produced.
    public var provenance: String {
        switch self {
        case .maskedMarginal:
            "One masked pass per position. The model does not see the residue it is scoring."
        case .wildTypeMarginal:
            "One pass over the whole sequence. Faster, and less accurate: "
                + "the model can see the residue it is scoring."
        }
    }
}

/// How far a scan has got.
public struct ScanProgress: Sendable, Hashable {
    public let completed: Int
    public let total: Int
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

public enum ScoringError: Error, Sendable {
    case noScorablePositions
    case sequenceTooLong(residues: Int, limit: Int)
    case modelUnavailable(String)
    case unexpectedOutputShape(String)
}

extension EmbeddingEngine {

    /// Variants scored per prediction by the SCORING model.
    ///
    /// **This MUST equal the `--scoring-batch` the scoring model was converted
    /// with**, and the length below must equal its `--default-bucket`. A
    /// mismatch fails at runtime, and only when a scan is actually run: it
    /// builds, converts and passes every other test. With the shape fixed
    /// rather than enumerated, Core ML rejects the wrong shape outright rather
    /// than quietly taking a slower path.
    ///
    /// 8 because the win saturates there: 31.2 ms per variant at batch 1, 21.6
    /// at 8, 22.6 at 16. This is a compute-bound workload, so a larger batch
    /// buys nothing.
    ///
    /// The backbone still scores at batch 1 and does so for every length but
    /// one. That is not a fallback but the faster path there: measured per
    /// variant, batch 8 loses to batch 1 by nearly three times at 128 and 256.
    public static let scoringBatchSize = 8

    /// The one length the scoring model is traced at, and so the only length
    /// it is used at.
    public static let scoringBucket = ShapeBucket.tokens384

    /// Score every canonical substitution at the given positions.
    ///
    /// - Parameters:
    ///   - sequence: the protein to score.
    ///   - positions: residue indices to score, or `nil` for every scorable
    ///     position. Non-canonical residues are skipped: the model has no
    ///     wild-type probability to compare against, so a delta against them
    ///     would be meaningless rather than merely uncertain.
    ///   - mode: masked marginal (accurate, one pass per position) or wild-type
    ///     marginal (one pass in total, faster and less accurate).
    ///   - onProgress: called as batches complete, for a progress bar.
    /// - Returns: the delta-LLR matrix over the positions actually scored.
    /// - Throws: ``ScoringError`` on unusable input or a model failure, and
    ///   `CancellationError` if the surrounding task is cancelled.
    public func maskedMarginals(
        _ sequence: ProteinSequence,
        positions: [Int]? = nil,
        mode: ScoringMode = .maskedMarginal,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> LLRMatrix {

        let scorable: [Int]
        if let positions {
            scorable = positions.filter { index in
                index >= 0 && index < sequence.count
                    && sequence.residues[index].identity.isScorable
            }
        } else {
            scorable = sequence.residues.filter(\.identity.isScorable).map(\.index)
        }
        guard !scorable.isEmpty else { throw ScoringError.noScorablePositions }

        // Scoring uses one bucket for the whole sequence. Tiling would change
        // the context each masked position sees between tiles, so a residue's
        // score would depend on which tile it landed in, which is not a
        // property any user would expect a fitness score to have.
        let tokenCount = tokeniserSpecialTokenCount + sequence.count
        guard let bucket = ShapeBucket.smallestFitting(tokenCount: tokenCount) else {
            throw ScoringError.sequenceTooLong(
                residues: sequence.count,
                limit: ShapeBucket.tokens1024.rawValue - tokeniserSpecialTokenCount)
        }

        let plan = try await scoringPlan(for: bucket)
        let canonical = AminoAcid.canonical
        let canonicalTokens = canonical.map { tokeniserIndex(for: .canonical($0)) }

        var columns: [[Double]] = []
        var wildTypes: [AminoAcid] = []
        columns.reserveCapacity(scorable.count)
        wildTypes.reserveCapacity(scorable.count)

        // The fast mode is one pass over the unmasked sequence: every
        // position's distribution is read from the same forward pass, so the
        // whole matrix costs what a single embedding costs.
        if mode == .wildTypeMarginal {
            // The wild-type pass reads every token from ONE unmasked row, so
            // it takes the backbone regardless of the plan: eight identical
            // rows would cost eight times as much for the same answer.
            let logits = try predictMasked(
                model: try await loadedModelForScoring(), sequence: sequence,
                positions: [], bucket: bucket)
            for position in scorable {
                guard case .canonical(let wildType) = sequence.residues[position].identity
                else { continue }
                let row = logits[tokenOffset(for: position)]
                columns.append(
                    Self.deltaLogRatios(
                        row: row, wildTypeToken: tokeniserIndex(for: .canonical(wildType)),
                        canonicalTokens: canonicalTokens))
                wildTypes.append(wildType)
            }
            onProgress?(ScanProgress(completed: scorable.count, total: scorable.count))
            return LLRMatrix(
                rows: canonical, positions: scorable, wildType: wildTypes, values: columns)
        }

        var completed = 0
        for chunk in scorable.chunked(into: plan.rows) {
            try Task.checkCancellation()

            let logits = try predictMasked(
                model: plan.model, sequence: sequence, positions: chunk,
                bucket: bucket, batchRows: plan.rows)

            for (offset, position) in chunk.enumerated() {
                guard case .canonical(let wildType) = sequence.residues[position].identity
                else { continue }

                columns.append(
                    Self.deltaLogRatios(
                        row: logits[offset],
                        wildTypeToken: tokeniserIndex(for: .canonical(wildType)),
                        canonicalTokens: canonicalTokens))
                wildTypes.append(wildType)
            }

            completed += chunk.count
            onProgress?(ScanProgress(completed: completed, total: scorable.count))
        }

        return LLRMatrix(
            rows: canonical, positions: scorable, wildType: wildTypes, values: columns)
    }
}

extension EmbeddingEngine {

    /// Delta log-likelihood ratios for one position's logit row.
    ///
    /// The log-softmax is taken over the FULL vocabulary and the canonical
    /// twenty are then read out of it. Normalising over only the twenty would
    /// divide away the probability the model assigns to gaps, `<mask>` and the
    /// other special tokens, which inflates every score by a different amount
    /// at every position: the matrix would still look entirely plausible.
    ///
    /// The wild type scores exactly zero, since it is subtracted from itself.
    static func deltaLogRatios(
        row: [Float], wildTypeToken: Int32, canonicalTokens: [Int32]
    ) -> [Double] {
        let maximum = row.max() ?? 0
        let total = row.reduce(0.0) { $0 + Foundation.exp(Double($1) - Double(maximum)) }
        let logTotal = Foundation.log(total) + Double(maximum)
        let wildTypeLog = Double(row[Int(wildTypeToken)]) - logTotal
        return canonicalTokens.map { token in
            Double(row[Int(token)]) - logTotal - wildTypeLog
        }
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
