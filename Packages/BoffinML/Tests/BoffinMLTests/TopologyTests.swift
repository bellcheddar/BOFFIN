//  TopologyTests.swift
//  BoffinMLTests
//
//  Span extraction from per-residue topology calls. These need no model: the
//  arithmetic is what turns a noisy per-residue prediction into the hard
//  constraint the Boundary tab enforces, and it is worth testing on its own
//  because a spurious span forbids a cut site that is actually fine.

import BoffinCore
import Testing

@testable import BoffinML

@Suite("Topology spans")
struct TopologyTests {

    private func predictions(_ pattern: String) -> HeadPredictions {
        let topology = pattern.map { character -> TopologyClass in
            switch character {
            case "M": .transmembrane
            case "S": .signalPeptide
            default: .outside
            }
        }
        return HeadPredictions(
            secondaryStructure: Array(repeating: .coil, count: topology.count),
            disorderProbability: Array(repeating: 0, count: topology.count),
            disorderThreshold: 0.5,
            topology: topology)
    }

    @Test("Contiguous runs become spans with inclusive bounds")
    func spans() {
        // Twenty membrane residues: a real helix length, and comfortably over
        // the twelve-residue floor.
        let result = predictions("oooo" + String(repeating: "M", count: 20) + "oooo")
        let spans = result.topologySpans()
        #expect(spans.count == 1)
        #expect(spans.first?.kind == .transmembrane)
        #expect(spans.first?.range == 4...23)
        #expect(spans.first?.length == 20)
    }

    @Test("Runs shorter than the minimum are dropped, not reported")
    func noise() {
        // Three residues is not a membrane crossing: a bilayer is about 30 A,
        // which takes roughly 20 residues of helix. The short run is far enough
        // from the long one that no merge can join them.
        let result = predictions("ooooMMMooooooooooooMMMMMMMMMMMMMMMMMMMMoooo")
        #expect(result.transmembraneSpanCount() == 1)
        #expect(result.topologySpans().allSatisfy { $0.length >= 12 })
        // With the floor lowered the short run reappears, so the filter is what
        // removed it rather than the extractor missing it.
        #expect(result.transmembraneSpanCount(minimumSpan: 3) == 2)
    }

    /// Why the default merge gap is zero.
    ///
    /// Merging short gaps is the obvious cure for low span precision and the
    /// validation sweep says it is the wrong one: it costs recall at every gap,
    /// because adjacent helices in a multi-pass membrane protein are separated
    /// by short loops. This pins the mechanism on a fixture rather than leaving
    /// it as an assertion in a comment.
    @Test("Merging would fuse two genuine helices separated by a short loop")
    func mergingFusesRealHelices() {
        // Two twenty-residue helices with a four-residue loop between them:
        // an entirely ordinary hairpin in a polytopic membrane protein.
        let helix = String(repeating: "M", count: 20)
        let result = predictions("oooo" + helix + "oooo" + helix + "oooo")

        // At the shipping default they stay two, which is correct.
        #expect(result.transmembraneSpanCount() == 2)

        // Merging across the loop reports one helix of forty-four residues,
        // which is not a thing.
        #expect(result.transmembraneSpanCount(mergeGap: 4, minimumSpan: 18) == 1)
        let fused = result.topologySpans(mergeGap: 4, minimumSpan: 18).first
        #expect(fused?.length == 44)
    }

    @Test("Merging never joins two different classes")
    func mergeRespectsClass() {
        // A signal peptide immediately followed by a membrane helix must stay
        // two things, however small the gap.
        let result = predictions("SSSSSSSSSSSSSSSSSSSSooMMMMMMMMMMMMMMMMMMMMoooo")
        let spans = result.topologySpans()
        #expect(spans.count == 2)
        #expect(spans[0].kind == .signalPeptide)
        #expect(spans[1].kind == .transmembrane)
    }

    @Test("Signal peptide and transmembrane spans are kept apart")
    func distinctClasses() {
        let result = predictions("SSSSSSSSSSSSSSSSSSSSooooMMMMMMMMMMMMMMMMMMMMoooo")
        let spans = result.topologySpans()
        #expect(spans.count == 2)
        #expect(spans.first?.kind == .signalPeptide)
        #expect(spans.last?.kind == .transmembrane)
        #expect(result.transmembraneSpanCount() == 1)
    }

    @Test("A span running to the last residue is closed, not dropped")
    func trailingSpan() {
        let result = predictions("oooo" + String(repeating: "M", count: 20))
        let spans = result.topologySpans()
        #expect(spans.count == 1)
        #expect(spans.first?.range.upperBound == 23)
    }

    @Test("No head means no prediction, which is not the same as soluble")
    func absentHead() {
        let result = HeadPredictions(
            secondaryStructure: Array(repeating: .coil, count: 40),
            disorderProbability: Array(repeating: 0, count: 40),
            disorderThreshold: 0.5,
            topology: nil)
        #expect(result.topology == nil)
        #expect(result.topologySpans().isEmpty)
        // No track at all, rather than an empty one that reads as "checked, and
        // there is nothing there".
        #expect(result.topologyTrack() == nil)
    }

    @Test("The track carries the span count a reader actually wants")
    func track() {
        let seven = String(
            repeating: "oooooMMMMMMMMMMMMMMMMMMMMMMoooo", count: 7)
        let result = predictions(seven)
        #expect(result.transmembraneSpanCount() == 7)
        let track = result.topologyTrack()
        #expect(track?.title.contains("7 transmembrane spans") == true)
        if case .spans(let spans) = track?.values {
            #expect(spans.count == 7)
        } else {
            Issue.record("expected a span track")
        }
    }
}
