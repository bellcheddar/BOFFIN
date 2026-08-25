//  FamilyMotifTests.swift
//  BoffinCoreTests
//
//  Written from the published definitions and checked against proteins whose
//  residue numbers appear in textbooks. Hard rule 6: a motif annotation that is
//  silently off by a few residues is worse than none, because it will be
//  believed and it will be used to interpret a mutation.

import Foundation
import Testing

@testable import BoffinCore

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sequences")
}

private func fixture(_ name: String) throws -> ProteinSequence {
    let text = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    let letters = text.split(separator: "\n").dropFirst().joined()
    return ProteinSequence(name: name, letters: letters, source: .fixture(name: name))
}

/// One-based residue number, as every paper and tool quotes it.
private func oneBased(_ motif: Motif) -> Int { motif.range.lowerBound + 1 }

@Suite("Protein kinase motifs")
struct KinaseMotifTests {

    @Test("CDK2's catalytic machinery lands on its textbook residue numbers")
    func cdk2Motifs() throws {
        // Human CDK2, UniProt P24941. These numbers are in every kinase review:
        // G-loop G11, beta-3 lysine K33, gatekeeper F80, HRD H125, DFG D145.
        let cdk2 = try fixture("P24941_CDK2_HUMAN.fasta")
        let motifs = FamilyMotifs.proteinKinase(in: cdk2)
        #expect(!motifs.isEmpty, "CDK2 was not recognised as a kinase")

        let byName = Dictionary(uniqueKeysWithValues: motifs.map { ($0.name, $0) })

        #expect(oneBased(byName["Glycine-rich loop"] ?? motifs[0]) == 11)
        #expect(byName["Glycine-rich loop"]?.matched == "GEGTYG")

        #expect(oneBased(byName["beta-3 lysine"] ?? motifs[0]) == 33)

        #expect(oneBased(byName["Catalytic HRD"] ?? motifs[0]) == 125)
        #expect(byName["Catalytic HRD"]?.matched == "HRD")

        #expect(oneBased(byName["DFG"] ?? motifs[0]) == 145)
        #expect(byName["DFG"]?.matched == "DFG")
    }

    @Test("Ubiquitin is not a kinase")
    func ubiquitinIsNotAKinase() throws {
        // The negative control that matters. A motif finder that answers
        // confidently for everything is worse than useless.
        let ubiquitin = try fixture("1UBQ.fasta")
        #expect(FamilyMotifs.proteinKinase(in: ubiquitin).isEmpty)
    }

    @Test("A GPCR is not a kinase")
    func gpcrIsNotAKinase() throws {
        let receptor = try fixture("P07550_ADRB2_HUMAN.fasta")
        #expect(FamilyMotifs.proteinKinase(in: receptor).isEmpty)
    }

    @Test("PETase is not a kinase")
    func petaseIsNotAKinase() throws {
        let petase = try fixture("A0A0K8P6T7_PETASE.fasta")
        #expect(FamilyMotifs.proteinKinase(in: petase).isEmpty)
    }

    @Test("HRD and DFG must be separated by an activation loop")
    func orderingIsEnforced() {
        // HRD occurs by chance about once per 8,000 residues, so an
        // unconstrained search finds spurious hits on any large protein and
        // labels them confidently. Adjacent motifs are not a kinase.
        let contrived = ProteinSequence(
            name: "contrived",
            letters: String(repeating: "A", count: 100) + "HRDDFG"
                + String(repeating: "A", count: 100),
            source: .pasted)
        #expect(FamilyMotifs.proteinKinase(in: contrived).isEmpty)
    }

    @Test("A short sequence is refused rather than guessed at")
    func shortSequenceIsRefused() {
        let short = ProteinSequence(name: "t", letters: "HRDAAAAAAAAAAAAAADFG", source: .pasted)
        #expect(FamilyMotifs.proteinKinase(in: short).isEmpty)
    }
}

@Suite("Class A GPCR motifs")
struct GPCRMotifTests {

    @Test("Beta-2 adrenergic receptor carries DRY, CWxP and NPxxY in order")
    func adrb2Motifs() throws {
        let receptor = try fixture("P07550_ADRB2_HUMAN.fasta")
        let motifs = FamilyMotifs.classAGPCR(in: receptor)
        #expect(motifs.count == 3, "expected three micro-switches, got \(motifs.count)")

        let names = motifs.map(\.name)
        #expect(names == ["D[ER]Y", "CWxP", "NPxxY"], "motifs out of order: \(names)")

        // They must appear on TM3, TM6 and TM7 respectively, so strictly
        // increasing and well separated.
        for (earlier, later) in zip(motifs, motifs.dropFirst()) {
            #expect(later.range.lowerBound > earlier.range.upperBound)
        }
    }

    @Test("Ubiquitin is not a GPCR")
    func ubiquitinIsNotAGPCR() throws {
        let ubiquitin = try fixture("1UBQ.fasta")
        #expect(FamilyMotifs.classAGPCR(in: ubiquitin).isEmpty)
    }

    @Test("A kinase is not a GPCR")
    func kinaseIsNotAGPCR() throws {
        let cdk2 = try fixture("P24941_CDK2_HUMAN.fasta")
        #expect(FamilyMotifs.classAGPCR(in: cdk2).isEmpty)
    }
}

@Suite("Motif tracks")
struct MotifTrackTests {

    @Test("Motifs become a span track that aligns with the sequence")
    func motifsBecomeATrack() throws {
        let cdk2 = try fixture("P24941_CDK2_HUMAN.fasta")
        let motifs = FamilyMotifs.proteinKinase(in: cdk2)
        let track = try #require(FamilyMotifs.track(motifs))
        try track.validate(against: cdk2)
    }

    @Test("No motifs means no track, rather than an empty one")
    func noMotifsMeansNoTrack() {
        #expect(FamilyMotifs.track([]) == nil)
    }
}
