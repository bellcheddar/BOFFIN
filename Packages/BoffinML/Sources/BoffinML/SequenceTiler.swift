//  SequenceTiler.swift
//  BoffinML
//
//  Sequences longer than the largest shape bucket are split into overlapping
//  tiles and stitched back together.
//
//  This is pure arithmetic on purpose. Tiling bugs are the invisible kind: a
//  plan that drops a residue, or overlaps by the wrong amount, produces a track
//  that is the right length and quietly wrong in the middle. Keeping the
//  planning separate from the inference means it can be checked exhaustively
//  without a model.

import BoffinCore
import Foundation

/// How a long sequence is divided for inference.
public struct TilePlan: Sendable, Hashable {
    /// One inference pass over a contiguous residue range.
    public struct Tile: Sendable, Hashable {
        /// Residues fed to the model, including the overlap shared with
        /// neighbouring tiles.
        public let residues: Range<Int>
        /// The shape bucket this tile is padded to.
        public let bucket: ShapeBucket

        public init(residues: Range<Int>, bucket: ShapeBucket) {
            self.residues = residues
            self.bucket = bucket
        }
    }

    public let tiles: [Tile]
    public let residueCount: Int

    /// Whether the sequence fitted in one pass.
    public var isSingleTile: Bool { tiles.count == 1 }
}

public enum SequenceTiler {

    /// Plan the inference passes for a sequence.
    ///
    /// - Parameters:
    ///   - residueCount: how many residues to cover.
    ///   - specialTokens: tokens the tokeniser wraps around each tile (`<cls>`
    ///     and `<eos>`), which consume bucket capacity and must be accounted
    ///     for or the largest tile overflows its buffer.
    ///   - overlap: residues shared between consecutive tiles, averaged when
    ///     stitching so the join is not a visible seam.
    /// - Returns: a plan whose tiles cover every residue exactly once or twice,
    ///   never zero times.
    public static func plan(
        residueCount: Int,
        specialTokens: Int = 2,
        overlap: Int = ShapeBucket.tileOverlap
    ) -> TilePlan {
        guard residueCount > 0 else {
            return TilePlan(tiles: [], residueCount: 0)
        }

        let tokenCount = residueCount + specialTokens
        if let bucket = ShapeBucket.smallestFitting(tokenCount: tokenCount) {
            return TilePlan(
                tiles: [TilePlan.Tile(residues: 0..<residueCount, bucket: bucket)],
                residueCount: residueCount)
        }

        // Tiling. The largest bucket must also hold the special tokens, so the
        // usable residue capacity is smaller than the bucket itself. Forgetting
        // that overflows the token buffer on exactly the longest sequences,
        // which are the ones nobody tests by hand.
        let largest = ShapeBucket.tokens1024
        let capacity = largest.rawValue - specialTokens
        precondition(capacity > overlap, "overlap must be smaller than a tile")

        let stride = capacity - overlap
        var tiles: [TilePlan.Tile] = []
        var start = 0

        while start < residueCount {
            let end = min(start + capacity, residueCount)
            let bucket =
                ShapeBucket.smallestFitting(tokenCount: (end - start) + specialTokens) ?? largest
            tiles.append(TilePlan.Tile(residues: start..<end, bucket: bucket))
            if end == residueCount { break }
            start += stride
        }

        return TilePlan(tiles: tiles, residueCount: residueCount)
    }

    /// Stitch per-tile per-residue vectors into one array covering the sequence.
    ///
    /// Overlapping positions are averaged. Averaging rather than taking the last
    /// writer matters: the model sees different context in each tile, and the
    /// edge of a tile is where its context is most truncated, so preferring one
    /// arbitrarily would bake the worst estimate into the seam.
    ///
    /// - Returns: `residueCount` vectors, or `nil` if a tile's output does not
    ///   match the range it claims to cover.
    public static func stitch(
        _ tileOutputs: [(range: Range<Int>, vectors: [[Float]])],
        residueCount: Int
    ) -> [[Float]]? {
        guard residueCount > 0 else { return [] }
        guard let width = tileOutputs.first?.vectors.first?.count else { return nil }

        var sums = [[Float]](repeating: [Float](repeating: 0, count: width), count: residueCount)
        var counts = [Float](repeating: 0, count: residueCount)

        for output in tileOutputs {
            guard output.vectors.count == output.range.count else { return nil }
            for (offset, index) in output.range.enumerated() {
                guard index < residueCount else { return nil }
                let vector = output.vectors[offset]
                guard vector.count == width else { return nil }
                for component in 0..<width {
                    sums[index][component] += vector[component]
                }
                counts[index] += 1
            }
        }

        // A residue covered by no tile would silently come back as zeros, which
        // reads as a real (and very confident) embedding rather than as a gap.
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }

        for index in 0..<residueCount where counts[index] > 1 {
            let divisor = counts[index]
            for component in 0..<width {
                sums[index][component] /= divisor
            }
        }
        return sums
    }
}
