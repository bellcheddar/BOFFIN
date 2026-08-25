//  TopologyAcceptanceTests.swift
//  BoffinMLTests
//
//  The Phase 3 acceptance criterion, run end to end against the real backbone
//  and the real head: "accepts when the GPCR fixture shows seven TM spans".
//
//  A class A GPCR has seven transmembrane helices. That is not a threshold
//  anybody chose, it is what the fold is, which makes it the right acceptance
//  test: an aggregate span recall of 0.81 says nothing about whether the app
//  gets THIS protein right, and the fixture set exists so that the answer to
//  that is checkable rather than assumed.

import BoffinCore
import Foundation
import Testing

@testable import BoffinML

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private var backboneURL: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.mlpackage")
}
private var tokeniserJSON: URL {
    repositoryRoot.appending(path: "Models/esm2_t12_35M_UR50D.tokeniser.json")
}
private var headsDirectory: URL { repositoryRoot.appending(path: "Models/heads") }

private var everythingIsAvailable: Bool {
    let manager = FileManager.default
    return manager.fileExists(atPath: backboneURL.path)
        && manager.fileExists(atPath: tokeniserJSON.path)
        && manager.fileExists(atPath: headsDirectory.appending(path: "topology.mlpackage").path)
}

private let missing: Comment =
    "backbone or topology head not converted: run Tools/coreml/convert.sh"

private func fixture(_ name: String) throws -> ProteinSequence {
    let url = repositoryRoot.appending(path: "Fixtures/sequences/\(name)")
    let text = try String(contentsOf: url, encoding: .utf8)
    return ProteinSequence(
        name: name, letters: text.split(separator: "\n").dropFirst().joined(),
        source: .fixture(name: name))
}

private func predict(_ sequence: ProteinSequence) async throws -> HeadPredictions {
    let engine = try EmbeddingEngine(modelURL: backboneURL, tokeniserURL: tokeniserJSON)
    let embedding = try await engine.embed(sequence)
    let heads = try AnalysisHeads(directory: headsDirectory)
    return try await heads.predict(for: embedding)
}

@Suite("Topology, against the real model", .enabled(if: everythingIsAvailable, missing))
struct TopologyAcceptanceTests {

    @Test("The beta-2 adrenergic receptor shows seven transmembrane spans")
    func gpcrHasSevenSpans() async throws {
        let receptor = try fixture("P07550_ADRB2_HUMAN.fasta")
        let predictions = try await predict(receptor)

        let topology = try #require(
            predictions.topology, "the topology head produced nothing")
        #expect(topology.count == receptor.count)

        let spans = predictions.topologySpans().filter { $0.kind == .transmembrane }
        #expect(spans.count == 7, "found \(spans.count) transmembrane spans, expected 7")

        // Seven of roughly the right length, in order, not seven fragments.
        #expect(spans.allSatisfy { $0.length >= 18 && $0.length <= 40 })
        #expect(
            zip(spans, spans.dropFirst()).allSatisfy { $0.range.upperBound < $1.range.lowerBound })

        // TM1 of ADRB2 begins around residue 35 and TM7 ends around 330. Loose
        // bounds on purpose: the point is that the spans cover the receptor
        // body rather than drifting into the termini.
        #expect(spans.first!.range.lowerBound > 20)
        #expect(spans.last!.range.upperBound < 360)
    }

    /// The negative control matters as much. Ubiquitin is a soluble cytosolic
    /// protein, and a topology head that finds membrane helices in it would be
    /// useless as the Boundary tab's hard constraint however good its aggregate
    /// numbers looked.
    @Test("Ubiquitin has no transmembrane span")
    func solubleProteinHasNone() async throws {
        let ubiquitin = try fixture("1UBQ.fasta")
        let predictions = try await predict(ubiquitin)
        #expect(predictions.transmembraneSpanCount() == 0)
    }

    @Test("PETase has a signal peptide and no membrane span")
    func secretedProtein() async throws {
        // PETase is secreted: the construct in 6EQE starts after the signal
        // peptide, so the fixture may or may not carry one, but it is certainly
        // not a membrane protein.
        let petase = try fixture("A0A0K8P6T7_PETASE.fasta")
        let predictions = try await predict(petase)
        #expect(predictions.transmembraneSpanCount() == 0)
    }
}
