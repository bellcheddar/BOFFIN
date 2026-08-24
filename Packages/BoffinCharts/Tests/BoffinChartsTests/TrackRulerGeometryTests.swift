//  TrackRulerGeometryTests.swift
//  BoffinChartsTests
//
//  Virtualisation bugs do not look like bugs. Drawing too few residues reads as
//  a rendering glitch, and drawing too many looks perfectly correct while
//  quietly missing the frame budget. Neither shows up in a screenshot, so the
//  arithmetic is pinned here instead.

import CoreGraphics
import Testing

@testable import BoffinCharts

@Suite("Ruler virtualisation")
struct VisibleRangeTests {

    @Test("Only the residues on screen, plus overscan, are drawn")
    func drawsOnlyWhatIsVisible() {
        // 10,000 residues at 12 points each is 120,000 points wide. A 400 point
        // viewport shows about 34 of them: if this ever returned the whole
        // sequence the 120 Hz budget is gone.
        let range = TrackRulerGeometry.visibleRange(
            viewport: 0...400, residueWidth: 12, residueCount: 10_000, overscan: 16)
        #expect(range.lowerBound == 0)
        #expect(range.count < 100, "drew \(range.count) residues for a 400 point viewport")
    }

    @Test("Scrolling moves the drawn window rather than growing it")
    func windowMovesRatherThanGrows() {
        // Compared away from position 0 deliberately. At the very start the
        // window is clamped and loses its leading overscan, so it is legitimately
        // narrower than a mid-sequence one: comparing the two would assert
        // something false about clamping rather than about scrolling.
        let early = TrackRulerGeometry.visibleRange(
            viewport: 3000...3400, residueWidth: 12, residueCount: 10_000)
        let later = TrackRulerGeometry.visibleRange(
            viewport: 6000...6400, residueWidth: 12, residueCount: 10_000)
        #expect(later.lowerBound > early.lowerBound)
        #expect(later.count == early.count)
    }

    @Test("The window at the very start is clamped, so it is narrower")
    func windowAtStartIsClamped() {
        let atStart = TrackRulerGeometry.visibleRange(
            viewport: 0...400, residueWidth: 12, residueCount: 10_000)
        let midway = TrackRulerGeometry.visibleRange(
            viewport: 6000...6400, residueWidth: 12, residueCount: 10_000)
        #expect(atStart.lowerBound == 0)
        #expect(atStart.count < midway.count)
    }

    @Test("Overscan extends both edges")
    func overscanExtendsBothEdges() {
        let withOverscan = TrackRulerGeometry.visibleRange(
            viewport: 1200...1600, residueWidth: 10, residueCount: 1000, overscan: 16)
        // Viewport covers residues 120 to 160; with 16 overscan, 104 to 177.
        #expect(withOverscan.lowerBound == 104)
        #expect(withOverscan.upperBound == 177)
    }

    @Test("The range is clamped at the start of the sequence")
    func clampedAtStart() {
        // Rubber-band scrolling produces negative offsets. Without clamping this
        // indexes before the first residue and crashes.
        let range = TrackRulerGeometry.visibleRange(
            viewport: (-500)...100, residueWidth: 10, residueCount: 100)
        #expect(range.lowerBound == 0)
    }

    @Test("The range is clamped at the end of the sequence")
    func clampedAtEnd() {
        let range = TrackRulerGeometry.visibleRange(
            viewport: 900...2000, residueWidth: 10, residueCount: 100)
        #expect(range.upperBound == 100)
        #expect(range.lowerBound <= range.upperBound)
    }

    @Test("A viewport entirely past the end yields an empty, valid range")
    func pastTheEndIsEmptyNotInverted() {
        // An inverted Range traps at runtime, so this must degrade to empty.
        let range = TrackRulerGeometry.visibleRange(
            viewport: 5000...6000, residueWidth: 10, residueCount: 100)
        #expect(range.lowerBound <= range.upperBound)
        #expect(range.isEmpty)
    }

    @Test("An empty sequence yields an empty range, not a crash")
    func emptySequenceIsSafe() {
        let range = TrackRulerGeometry.visibleRange(
            viewport: 0...400, residueWidth: 12, residueCount: 0)
        #expect(range.isEmpty)
    }

    @Test("A zero residue width yields an empty range rather than dividing by zero")
    func zeroWidthIsSafe() {
        let range = TrackRulerGeometry.visibleRange(
            viewport: 0...400, residueWidth: 0, residueCount: 100)
        #expect(range.isEmpty)
    }

    @Test("Every index the range yields is inside the sequence")
    func allIndicesAreInBounds() {
        // The property that actually matters: whatever the viewport, the drawing
        // loop must never index outside the residue array.
        for offset in stride(from: -1000.0, through: 3000.0, by: 137.0) {
            let range = TrackRulerGeometry.visibleRange(
                viewport: CGFloat(offset)...CGFloat(offset + 400),
                residueWidth: 9, residueCount: 250)
            for index in range {
                #expect(index >= 0 && index < 250, "index \(index) escaped at offset \(offset)")
            }
        }
    }
}

@Suite("Residue hit testing")
struct ResidueIndexTests {

    @Test("A tap maps to the residue under it")
    func tapMapsToResidue() {
        #expect(TrackRulerGeometry.residueIndex(atX: 0, residueWidth: 10, residueCount: 100) == 0)
        #expect(TrackRulerGeometry.residueIndex(atX: 9, residueWidth: 10, residueCount: 100) == 0)
        #expect(TrackRulerGeometry.residueIndex(atX: 10, residueWidth: 10, residueCount: 100) == 1)
        #expect(TrackRulerGeometry.residueIndex(atX: 55, residueWidth: 10, residueCount: 100) == 5)
    }

    @Test("A tap beyond either end clamps into the sequence")
    func tapsOutsideClamp() {
        #expect(TrackRulerGeometry.residueIndex(atX: -50, residueWidth: 10, residueCount: 100) == 0)
        #expect(
            TrackRulerGeometry.residueIndex(atX: 9999, residueWidth: 10, residueCount: 100) == 99)
    }

    @Test("Hit testing an empty sequence does not crash")
    func emptySequenceHitTest() {
        #expect(TrackRulerGeometry.residueIndex(atX: 42, residueWidth: 10, residueCount: 0) == 0)
    }
}

@Suite("Axis ticks")
struct AxisTickTests {

    @Test("Tick intervals are numbers a person would choose")
    func stepsAreRoundNumbers() {
        #expect(TrackRulerGeometry.niceStep(atLeast: 1) == 1)
        #expect(TrackRulerGeometry.niceStep(atLeast: 3) == 5)
        #expect(TrackRulerGeometry.niceStep(atLeast: 7) == 10)
        #expect(TrackRulerGeometry.niceStep(atLeast: 11) == 20)
        #expect(TrackRulerGeometry.niceStep(atLeast: 37) == 50)
        #expect(TrackRulerGeometry.niceStep(atLeast: 63) == 100)
    }

    @Test("A step is never smaller than requested, or labels would collide")
    func stepIsNeverBelowTheMinimum() {
        for minimum in 1...500 {
            #expect(TrackRulerGeometry.niceStep(atLeast: minimum) >= minimum)
        }
    }

    @Test("Zooming in gives denser ticks, zooming out sparser")
    func tickDensityFollowsZoom() {
        let zoomedIn = TrackRulerGeometry.residuesPerTick(residueWidth: 28)
        let zoomedOut = TrackRulerGeometry.residuesPerTick(residueWidth: 1.5)
        #expect(zoomedIn < zoomedOut)
    }

    @Test("A zero width does not divide by zero")
    func zeroWidthTicks() {
        #expect(TrackRulerGeometry.residuesPerTick(residueWidth: 0) == 1)
    }
}
