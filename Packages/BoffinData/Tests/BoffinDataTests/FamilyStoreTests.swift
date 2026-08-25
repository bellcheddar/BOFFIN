//  FamilyStoreTests.swift
//  BoffinDataTests
//
//  Numbering that is wrong by two residues is invisible to everyone who reads
//  it, so these check against proteins whose numbers are in textbooks, and
//  check just as hard that a protein from the wrong family is REFUSED.

import BoffinCore
import Foundation
import Testing

@testable import BoffinData

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sequences")
}

private func fixture(_ name: String) throws -> ProteinSequence {
    let text = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    return ProteinSequence(
        name: name, letters: text.split(separator: "\n").dropFirst().joined(),
        source: .fixture(name: name))
}

@Suite("Family numbering tables")
struct FamilyStoreTests {

    @Test("The bundled tables load")
    func tablesLoad() throws {
        let store = try FamilyStore()
        #expect(store.receptorCount >= 10, "only \(store.receptorCount) receptors bundled")
        #expect(store.kinaseCount >= 500, "only \(store.kinaseCount) kinases bundled")
    }

    @Test("CDK2 maps onto KLIFS numbering against a kinase reference")
    func cdk2MapsToKlifs() throws {
        let store = try FamilyStore()
        let cdk2 = try fixture("P24941_CDK2_HUMAN.fasta")
        let result = try store.klifsNumbering(for: cdk2)

        // CDK2 is itself in the table, so it should match itself essentially
        // perfectly. Anything less means the alignment or the gap handling is
        // wrong.
        #expect(result.identity > 0.9, "identity was only \(result.identity)")
        #expect(!result.numbers.isEmpty)

        // KLIFS position 17 is the beta-3 lysine and 81 to 83 the DFG. Mapped
        // back onto CDK2 those are K33 and D145 to G147.
        let byLabel = Dictionary(
            result.numbers.map { ($0.label, $0.residue) }, uniquingKeysWith: { first, _ in first })
        #expect(byLabel["KLIFS 17"].map { $0 + 1 } == 33, "beta-3 lysine did not land on K33")
        #expect(byLabel["KLIFS 81"].map { $0 + 1 } == 145, "DFG aspartate did not land on D145")
        #expect(byLabel["KLIFS 83"].map { $0 + 1 } == 147)
    }

    @Test("Beta-2 adrenergic receptor maps onto GPCRdb numbering")
    func adrb2MapsToGpcrdb() throws {
        let store = try FamilyStore()
        let receptor = try fixture("P07550_ADRB2_HUMAN.fasta")
        let result = try store.gpcrdbNumbering(for: receptor)

        #expect(result.reference == "adrb2_human", "matched \(result.reference) instead")
        #expect(result.identity > 0.9)

        // GPCRdb 3x50 is the arginine of the DRY motif, R131 in ADRB2.
        let arginine = result.numbers.first { $0.label.hasPrefix("3x50") }
        #expect(arginine.map { $0.residue + 1 } == 131, "3x50 did not land on R131")
    }

    @Test("Ubiquitin is refused by both schemes rather than numbered")
    func ubiquitinIsRefused() throws {
        // The test that matters most. A numbering returned for a protein from
        // the wrong family is not a weak answer, it is a wrong one, and the
        // number will be copied out of the app without the caveat.
        let store = try FamilyStore()
        let ubiquitin = try fixture("1UBQ.fasta")
        #expect(throws: FamilyStoreError.self) { try store.klifsNumbering(for: ubiquitin) }
        #expect(throws: FamilyStoreError.self) { try store.gpcrdbNumbering(for: ubiquitin) }
    }

    @Test("A GPCR is refused by the kinase scheme")
    func gpcrIsRefusedByKlifs() throws {
        let store = try FamilyStore()
        let receptor = try fixture("P07550_ADRB2_HUMAN.fasta")
        #expect(throws: FamilyStoreError.self) { try store.klifsNumbering(for: receptor) }
    }

    @Test("A kinase is refused by the GPCR scheme")
    func kinaseIsRefusedByGpcrdb() throws {
        let store = try FamilyStore()
        let cdk2 = try fixture("P24941_CDK2_HUMAN.fasta")
        #expect(throws: FamilyStoreError.self) { try store.gpcrdbNumbering(for: cdk2) }
    }

    @Test("The identity floor is stated, not hidden in a caveat")
    func identityFloorIsExplicit() {
        #expect(NumberingResult.minimumIdentity >= 0.3)
    }

    @Test("Numbering becomes a track that aligns with the sequence")
    func numberingBecomesATrack() throws {
        let store = try FamilyStore()
        let cdk2 = try fixture("P24941_CDK2_HUMAN.fasta")
        let result = try store.klifsNumbering(for: cdk2)
        let track = try #require(
            FamilyStore.track(result, residueCount: cdk2.count, title: "KLIFS"))
        try track.validate(against: cdk2)
        #expect(track.title.contains("identity"), "the track must carry its own confidence")
    }
}
