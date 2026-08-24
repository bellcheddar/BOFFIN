//  EmbeddingEngine.swift
//  BoffinML
//
//  Invariant 1 of the build plan: one forward pass, four fan-outs.
//
//  Every analytical feature in BOFFIN reads from a single ESM-2 pass on the
//  Neural Engine. Per-residue hidden states drive order and boundaries,
//  masked-token logits drive fitness, and the pooled embedding drives family
//  and homolog search. Do not build independent pipelines per feature.
//
//  Phase 0 establishes the module boundary and the actor's public surface.
//  Phase 2 supplies the Core ML backing, shape bucketing, tiling, warm-up and
//  the parity and residency gates.

import BoffinCore

/// Sequence-length buckets for the Neural Engine.
///
/// The ANE will not accept fully dynamic sequence lengths, so the converted
/// model declares `EnumeratedShapes` over these token counts. A sequence is
/// padded up to the smallest fitting bucket, the padding is masked, and the
/// output is sliced back. Sequences longer than the largest bucket are tiled
/// with overlap and stitched.
public enum ShapeBucket: Int, CaseIterable, Sendable, Comparable {
    case tokens128 = 128
    case tokens256 = 256
    case tokens384 = 384
    case tokens512 = 512
    case tokens768 = 768
    case tokens1024 = 1024

    /// Residue overlap between tiles when a sequence exceeds the largest bucket.
    /// Overlapping positions are averaged when stitching.
    public static let tileOverlap = 128

    public static func < (lhs: ShapeBucket, rhs: ShapeBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The smallest bucket that fits `tokenCount`, or `nil` if the sequence
    /// must be tiled.
    public static func smallestFitting(tokenCount: Int) -> ShapeBucket? {
        allCases.first { $0.rawValue >= tokenCount }
    }
}

/// The single point of access to the backbone. Core ML models are not
/// thread-safe under concurrent prediction, so all traffic is serialised here.
public actor EmbeddingEngine {
    public init() {}

    /// Pay the ANE compilation cost at launch with a dummy input, so a user
    /// never sees it on their first real analysis.
    public func warmUp() async {
        // Phase 2.
    }
}
