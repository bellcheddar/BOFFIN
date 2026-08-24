//  SequenceTilerTests.swift
//  BoffinMLTests
//
//  Tiling bugs do not announce themselves. A plan that drops a residue, or
//  overlaps by the wrong amount, still produces a track of exactly the right
//  length that is quietly wrong somewhere in the middle. These tests check
//  coverage as a property rather than spot-checking a few lengths.

import Testing

@testable import BoffinML

@Suite("Tile planning")
struct TilePlanTests {

    @Test("A short sequence is one pass in the smallest fitting bucket")
    func shortSequenceIsOnePass() {
        // 300 residues plus cls and eos is 302 tokens, which fits 384.
        let plan = SequenceTiler.plan(residueCount: 300)
        #expect(plan.isSingleTile)
        #expect(plan.tiles.first?.bucket == .tokens384)
        #expect(plan.tiles.first?.residues == 0..<300)
    }

    @Test("Special tokens count against bucket capacity")
    func specialTokensConsumeCapacity() {
        // 1023 residues would fit 1024 tokens on its own, but with cls and eos
        // it needs 1025 and must therefore be tiled. Forgetting the special
        // tokens overflows the buffer on exactly the longest single-pass
        // sequences, which are the ones nobody checks by hand.
        #expect(SequenceTiler.plan(residueCount: 1022).isSingleTile)
        #expect(!SequenceTiler.plan(residueCount: 1023).isSingleTile)
    }

    @Test("A long sequence is tiled")
    func longSequenceIsTiled() {
        let plan = SequenceTiler.plan(residueCount: 3000)
        #expect(plan.tiles.count > 1)
    }

    @Test("Every residue is covered, for every length across the tiling boundary")
    func everyResidueIsCovered() {
        // The property that actually matters. Checked densely around the
        // single-pass boundary and out into multi-tile territory.
        for count in [1, 2, 127, 1021, 1022, 1023, 1024, 1025, 2000, 3000, 5000, 12_345] {
            let plan = SequenceTiler.plan(residueCount: count)
            var covered = [Bool](repeating: false, count: count)
            for tile in plan.tiles {
                for index in tile.residues { covered[index] = true }
            }
            #expect(covered.allSatisfy { $0 }, "residue uncovered at length \(count)")
        }
    }

    @Test("No tile exceeds its bucket once special tokens are added")
    func tilesFitTheirBuckets() {
        for count in [500, 1023, 2000, 5000, 20_000] {
            let plan = SequenceTiler.plan(residueCount: count)
            for tile in plan.tiles {
                #expect(
                    tile.residues.count + 2 <= tile.bucket.rawValue,
                    "tile of \(tile.residues.count) overflows bucket \(tile.bucket.rawValue)")
            }
        }
    }

    @Test("Consecutive tiles overlap by the declared amount")
    func tilesOverlap() {
        let plan = SequenceTiler.plan(residueCount: 5000)
        for (previous, next) in zip(plan.tiles, plan.tiles.dropFirst()) {
            let overlap = previous.residues.upperBound - next.residues.lowerBound
            // The final tile may overlap more, because it is pulled back to end
            // exactly at the C-terminus rather than running past it.
            #expect(overlap >= ShapeBucket.tileOverlap, "tiles overlapped by only \(overlap)")
        }
    }

    @Test("Tiles are ordered and start at the N-terminus")
    func tilesAreOrdered() {
        let plan = SequenceTiler.plan(residueCount: 4000)
        #expect(plan.tiles.first?.residues.lowerBound == 0)
        #expect(plan.tiles.last?.residues.upperBound == 4000)
        for (previous, next) in zip(plan.tiles, plan.tiles.dropFirst()) {
            #expect(next.residues.lowerBound > previous.residues.lowerBound)
        }
    }

    @Test("An empty sequence produces no tiles rather than one empty tile")
    func emptySequenceHasNoTiles() {
        #expect(SequenceTiler.plan(residueCount: 0).tiles.isEmpty)
    }

    @Test("Planning terminates for a very long sequence")
    func planningTerminates() {
        // Titin is about 34,000 residues. A stride that ever reached zero would
        // loop forever rather than fail.
        let plan = SequenceTiler.plan(residueCount: 34_350)
        #expect(plan.tiles.count > 30)
        #expect(plan.tiles.last?.residues.upperBound == 34_350)
    }
}

@Suite("Tile stitching")
struct TileStitchTests {

    private func vectors(_ value: Float, count: Int, width: Int = 3) -> [[Float]] {
        Array(repeating: [Float](repeating: value, count: width), count: count)
    }

    @Test("A single tile passes through unchanged")
    func singleTilePassesThrough() {
        let stitched = SequenceTiler.stitch(
            [(0..<10, vectors(1, count: 10))], residueCount: 10)
        #expect(stitched?.count == 10)
        #expect(stitched?.first == [1, 1, 1])
    }

    @Test("Overlapping positions are averaged, not overwritten")
    func overlapIsAveraged() {
        // The model sees different context in each tile, and a tile's edge is
        // where its context is most truncated. Taking the last writer would
        // bake the worst estimate into every seam.
        let stitched = SequenceTiler.stitch(
            [(0..<10, vectors(0, count: 10)), (5..<15, vectors(10, count: 10))],
            residueCount: 15)
        #expect(stitched?[0] == [0, 0, 0], "non-overlapping start should be untouched")
        #expect(stitched?[7] == [5, 5, 5], "overlap should be the mean of 0 and 10")
        #expect(stitched?[12] == [10, 10, 10], "non-overlapping end should be untouched")
    }

    @Test("A gap in coverage is rejected rather than returned as zeros")
    func gapIsRejected() {
        // Zeros would read as a real, and very confident, embedding.
        let stitched = SequenceTiler.stitch(
            [(0..<5, vectors(1, count: 5)), (10..<15, vectors(1, count: 5))],
            residueCount: 15)
        #expect(stitched == nil)
    }

    @Test("A tile whose output does not match its range is rejected")
    func mismatchedTileIsRejected() {
        let stitched = SequenceTiler.stitch(
            [(0..<10, vectors(1, count: 7))], residueCount: 10)
        #expect(stitched == nil)
    }

    @Test("Inconsistent vector widths are rejected")
    func inconsistentWidthIsRejected() {
        let mixed: [[Float]] = [[1, 2, 3], [1, 2]]
        #expect(SequenceTiler.stitch([(0..<2, mixed)], residueCount: 2) == nil)
    }

    @Test("An empty sequence stitches to nothing without erroring")
    func emptyStitch() {
        #expect(SequenceTiler.stitch([], residueCount: 0)?.isEmpty == true)
    }

    @Test("A real plan's tiles stitch to full coverage")
    func realPlanStitches() {
        // End to end over the planner's own output, so the two cannot disagree
        // about overlap without this failing.
        let count = 3000
        let plan = SequenceTiler.plan(residueCount: count)
        let outputs = plan.tiles.map { tile in
            (tile.residues, Array(repeating: [Float(1), 2, 3], count: tile.residues.count))
        }
        let stitched = SequenceTiler.stitch(outputs, residueCount: count)
        #expect(stitched?.count == count)
        #expect(stitched?.allSatisfy { $0 == [1, 2, 3] } == true)
    }
}
