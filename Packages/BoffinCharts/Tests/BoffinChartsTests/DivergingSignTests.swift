//  DivergingSignTests.swift
//  BoffinChartsTests
//
//  Sign has to mean the same thing everywhere.
//
//  `ScientificPalette` fixes the delta-LLR convention: negative is red, because
//  negative is destabilising or depleted, and positive is blue. The comment on
//  it says this is fixed "so the heatmap, the logo and the structure overlay
//  cannot disagree about sign".
//
//  They did disagree. The structure overlay min-max normalised every continuous
//  track onto its own blue-to-red ramp, so the most NEGATIVE residue of a
//  diverging track landed at fraction zero and was painted blue, while the ruler
//  directly above it painted the same residue red. Hydropathy is diverging, so
//  a user comparing the two saw one view calling a face hydrophilic-red and the
//  other calling it hydrophobic-red.
//
//  These tests are in the charts package because that is where the ruler's
//  default lives. The app-side overlay now routes through the same palette.

import SwiftUI
import Testing

@testable import BoffinCharts

@Suite("Diverging sign convention")
struct DivergingSignTests {

    /// Resolve a SwiftUI colour to something comparable.
    private func components(_ colour: Color) -> (r: Double, g: Double, b: Double) {
        let resolved = colour.resolve(in: EnvironmentValues())
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }

    @Test("The default diverging scale puts negative on red and positive on blue")
    func defaultScaleSign() {
        // The default in `TrackRulerStyle`, which is what any consumer that does
        // not supply its own gets. A flipped sign here would invert every
        // mutation heatmap and look entirely normal doing it.
        let style = TrackRulerStyle()
        let negative = components(style.divergingColour(-0.8))
        let positive = components(style.divergingColour(0.8))

        #expect(negative.r > negative.b, "negative should be red-dominant")
        #expect(positive.b > positive.r, "positive should be blue-dominant")
    }

    @Test("Magnitude changes intensity, not hue")
    func magnitudeDoesNotFlipHue() {
        // A weak negative is still red. If intensity were implemented by
        // interpolating towards the opposite end, a small negative would come
        // out bluish and the sign would be unreadable near zero, which is
        // exactly where a reader most needs it.
        let style = TrackRulerStyle()
        for magnitude in [0.1, 0.5, 1.0] {
            let negative = components(style.divergingColour(-magnitude))
            #expect(negative.r >= negative.b, "negative at \(magnitude) lost its red")
        }
        for magnitude in [0.1, 0.5, 1.0] {
            let positive = components(style.divergingColour(magnitude))
            #expect(positive.b >= positive.r, "positive at \(magnitude) lost its blue")
        }
    }

    @Test("Zero fades out rather than asserting a sign")
    func zeroIsNeutral() {
        // The midpoint of a diverging scale carries no claim, and a saturated
        // colour there would assert one.
        //
        // Neutrality is reached through OPACITY, not hue: the scale stays blue
        // or red and fades to invisible at zero. Checking the RGB channels
        // alone reports a fully blue colour at zero, which is true and
        // irrelevant, because it is drawn at alpha zero.
        let style = TrackRulerStyle()
        let atZero = style.divergingColour(0).resolve(in: EnvironmentValues())
        #expect(
            Double(atZero.opacity) < 0.1,
            "zero is drawn at opacity \(atZero.opacity), which asserts a sign it lacks")

        // And a strong value is actually visible, or the fade would be hiding
        // the track rather than expressing its midpoint.
        let strong = style.divergingColour(-1).resolve(in: EnvironmentValues())
        #expect(Double(strong.opacity) > 0.5)
    }
}
