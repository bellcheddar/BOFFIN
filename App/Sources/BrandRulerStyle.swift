//  BrandRulerStyle.swift
//  BOFFIN
//
//  Wires BoffinUI's palette into BoffinCharts' renderer.
//
//  This lives in the app rather than in either module because the dependency
//  rule forbids them seeing each other: BoffinCharts and BoffinUI both depend
//  on BoffinCore and nothing else. The app is the only place that legitimately
//  knows about both, which is exactly what "the app target wires everything"
//  means.

import BoffinCharts
import BoffinUI
import SwiftUI

extension TrackRulerStyle {
    static var boffin: TrackRulerStyle {
        TrackRulerStyle(
            background: .clear,
            axis: .secondary,
            text: .primary,
            mutedText: .secondary,
            selection: Brand.accent,
            trackFill: Brand.accent,
            categoryColour: { ScientificPalette.secondaryStructure($0) },
            sequentialColour: { value in
                let palette = ScientificPalette.sequential
                let position = value.clamped(to: 0...1) * Double(palette.count - 1)
                return palette[Int(position.rounded())]
            },
            divergingColour: { value in
                // Negative is red, positive is blue, matching the delta-LLR
                // convention fixed in BoffinUI so that sign means the same
                // thing everywhere in the app.
                let magnitude = min(abs(value), 1)
                let base = value < 0 ? ScientificPalette.llrNegative : ScientificPalette.llrPositive
                return base.opacity(0.25 + 0.75 * magnitude)
            })
    }
}

extension Comparable {
    fileprivate func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
