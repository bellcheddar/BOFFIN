//  TrackFanOutTests.swift
//  BoffinMLTests
//
//  Invariant 2 at the point of production.
//
//  "Everything is a `ResidueTrack`" is one of the project's two invariants, and
//  the reason it is stated as an invariant is that a misaligned track does not
//  crash: it draws a convincing picture of the wrong thing. Every track is
//  therefore validated against its sequence where it is produced.
//
//  `HeadPredictions.tracks()` is where the per-residue fan-out becomes tracks,
//  and **nothing tested it**. The app validates what it receives, so a
//  wrongly-sized track would have been caught at runtime by the store rather
//  than at build time by a test, and only for whichever head happened to be
//  wrong on whichever sequence was pasted.
//
//  These tests construct predictions of a known length and check the tracks
//  come out that length, which is the whole of the guarantee.

import BoffinCore
import Foundation
import Testing

@testable import BoffinML

@Suite("Track fan-out")
struct TrackFanOutTests {

    private let residueCount = 40

    private func sequence() -> ProteinSequence {
        // Forty residues of nothing in particular. The letters do not matter:
        // what is being checked is that the tracks are the same length as the
        // thing they claim to describe.
        ProteinSequence(
            name: "test", letters: String(repeating: "A", count: residueCount),
            source: .pasted)
    }

    private func predictions(
        length: Int, topology: [TopologyClass]? = nil
    ) -> HeadPredictions {
        HeadPredictions(
            secondaryStructure: Array(repeating: .coil, count: length),
            disorderProbability: Array(repeating: 0.1, count: length),
            disorderThreshold: 0.9,
            topology: topology,
            topologyMergeGap: 0,
            topologyMinimumSpan: 18)
    }

    @Test("Every track validates against the sequence it describes")
    func tracksAlignWithTheSequence() throws {
        let tracks = predictions(length: residueCount).tracks()
        #expect(!tracks.isEmpty, "the fan-out produced no tracks at all")

        for track in tracks {
            // The same call the store makes. If this throws, the app would
            // have shown a convincing picture of the wrong protein.
            try track.validate(against: sequence())
        }
    }

    @Test("A wrongly sized prediction is caught rather than drawn")
    func mismatchIsRejected() throws {
        // The failure the invariant exists for: a head returning one residue
        // too few, which is exactly what an off-by-one in tokenising or in the
        // BOS/EOS trim would produce. The track is well formed and describes a
        // different protein.
        let tracks = predictions(length: residueCount - 1).tracks()
        let target = sequence()

        var caught = false
        for track in tracks {
            do { try track.validate(against: target) } catch { caught = true }
        }
        #expect(caught, "a 39-residue track passed validation against 40 residues")
    }

    /// A topology with one transmembrane span long enough to survive the
    /// minimum-span filter.
    private func withMembraneSpan() -> [TopologyClass] {
        var classes = [TopologyClass](repeating: .outside, count: residueCount)
        for index in 10..<30 { classes[index] = .transmembrane }
        return classes
    }

    @Test("A real transmembrane span becomes a track")
    func membraneSpanAppears() {
        let without = predictions(length: residueCount).tracks()
        let with = predictions(length: residueCount, topology: withMembraneSpan()).tracks()
        #expect(
            with.count > without.count,
            "a twenty-residue transmembrane span produced no track")
    }

    @Test("A soluble protein draws no topology track, which is not the same as no prediction")
    func solubleDrawsNothing() {
        // Correct, and worth pinning because it looks like a gap. A topology of
        // all-outside has no spans, so there is nothing to draw and the track
        // is absent. That is the same ABSENCE as having no topology at all,
        // and the two are still distinguished where it matters: the Boundary
        // tab reads `topologySpans()` directly, not the track, because a solver
        // that cannot see transmembrane spans must refuse to enforce the
        // constraint rather than assume there is nothing to enforce.
        let soluble = predictions(
            length: residueCount,
            topology: Array(repeating: .outside, count: residueCount))
        #expect(soluble.topologyTrack() == nil, "an empty track would be a blank row")
        #expect(soluble.topology != nil, "the prediction itself is still present")

        let unpredicted = predictions(length: residueCount)
        #expect(unpredicted.topologyTrack() == nil)
        #expect(unpredicted.topology == nil, "and here there is genuinely no prediction")
    }

    @Test("Track identifiers are distinct, or the ruler stacks them wrongly")
    func identifiersAreUnique() {
        // The ruler keys on the identifier. Two tracks sharing one would show
        // one and silently drop the other, which reads as a head that failed to
        // run rather than a collision.
        let tracks = predictions(length: residueCount, topology: withMembraneSpan()).tracks()
        let identifiers = tracks.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }
}
