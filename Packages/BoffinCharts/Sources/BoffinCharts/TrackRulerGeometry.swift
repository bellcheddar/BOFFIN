//  TrackRulerGeometry.swift
//  BoffinCharts
//
//  The ruler's arithmetic, separated from its drawing so it can be tested
//  without a view. Virtualisation bugs are invisible by nature: drawing too few
//  residues looks like a rendering glitch and drawing too many looks correct
//  while missing the frame budget, so neither shows up in a screenshot.

import CoreGraphics
import Foundation

public enum TrackRulerGeometry {

    /// The residue index range to draw for a viewport, including overscan.
    ///
    /// Clamped to the sequence so a scroll past either end cannot index out of
    /// bounds, and returned as a half-open range so `count` is the number drawn.
    public static func visibleRange(
        viewport: ClosedRange<CGFloat>,
        residueWidth: CGFloat,
        residueCount: Int,
        overscan: Int = TrackRulerMetrics.overscanResidues
    ) -> Range<Int> {
        guard residueWidth > 0, residueCount > 0 else { return 0..<0 }

        let first = Int((viewport.lowerBound / residueWidth).rounded(.down)) - overscan
        let last = Int((viewport.upperBound / residueWidth).rounded(.down)) + overscan

        let lower = max(0, min(first, residueCount))
        let upper = max(lower, min(residueCount, last + 1))
        return lower..<upper
    }

    /// Which residue sits under a horizontal position.
    public static func residueIndex(
        atX x: CGFloat,
        residueWidth: CGFloat,
        residueCount: Int
    ) -> Int {
        guard residueWidth > 0, residueCount > 0 else { return 0 }
        let raw = Int((x / residueWidth).rounded(.down))
        return min(max(raw, 0), residueCount - 1)
    }

    /// Round a tick interval up to a 1, 2 or 5 times a power of ten.
    ///
    /// Axis labels should land on numbers a person would have chosen (10, 20,
    /// 50, 100), not on whatever the arithmetic produced (37, 63).
    public static func niceStep(atLeast minimum: Int) -> Int {
        guard minimum > 1 else { return 1 }
        let magnitude = pow(10.0, (log10(Double(minimum))).rounded(.down))
        for multiple in [1.0, 2.0, 5.0, 10.0] {
            let candidate = multiple * magnitude
            if candidate >= Double(minimum) { return Int(candidate) }
        }
        return minimum
    }

    /// Residues between axis ticks at a given zoom, so labels stay legible.
    public static func residuesPerTick(
        residueWidth: CGFloat,
        targetSpacing: CGFloat = 60
    ) -> Int {
        guard residueWidth > 0 else { return 1 }
        return niceStep(atLeast: max(1, Int((targetSpacing / residueWidth).rounded(.up))))
    }
}
