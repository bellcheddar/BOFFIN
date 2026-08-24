//  SequenceLogo.swift
//  BoffinCharts
//
//  Custom SwiftUI Canvas renderers: the track ruler, the delta-LLR heatmap and
//  the sequence logo. No web charting anywhere.
//
//  Phase 0 establishes the module boundary. Phase 1 supplies the ruler and
//  Phase 4 the heatmap and logo.
//
//  Accessibility is not optional polish here: every chart carries an
//  accessibilityChartDescriptor so VoiceOver users get Audio Graphs, and every
//  track exposes per-residue values as accessibility elements.

import BoffinCore
import Foundation

/// Information-content mathematics for the sequence logo.
///
/// Per position, `R = log2(20) - H` where `H = -sum(p * log2(p))`, and each
/// glyph is drawn at height `p(aa) * R`. Kept here as pure functions so they
/// can be tested against hand-computed fixtures without a view in the loop.
public enum InformationContent {

    /// Maximum information content for a twenty-letter alphabet, in bits.
    public static let maximumBits = log2(20.0)

    /// Shannon entropy of a probability distribution, in bits.
    ///
    /// Zero-probability terms contribute nothing (the limit of `p log p` as `p`
    /// tends to zero), so they are skipped rather than producing a NaN.
    public static func entropy(_ probabilities: [Double]) -> Double {
        -probabilities.reduce(into: 0.0) { total, p in
            guard p > 0 else { return }
            total += p * log2(p)
        }
    }

    /// Information content at a position, in bits: `log2(20) - H`.
    public static func bits(_ probabilities: [Double]) -> Double {
        maximumBits - entropy(probabilities)
    }
}
