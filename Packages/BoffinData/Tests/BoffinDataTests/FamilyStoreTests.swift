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
        //
        // The labels are KLIFS's own (`III.17`, `xDFG.81`) rather than a bare
        // "KLIFS 17", because a position number alone is not something a reader
        // can act on and the region name is the half that carries the meaning.
        let byLabel = Dictionary(
            result.numbers.map { ($0.label, $0.residue) }, uniquingKeysWith: { first, _ in first })
        #expect(byLabel["III.17"].map { $0 + 1 } == 33, "beta-3 lysine did not land on K33")
        #expect(byLabel["xDFG.81"].map { $0 + 1 } == 145, "DFG aspartate did not land on D145")
        #expect(byLabel["xDFG.83"].map { $0 + 1 } == 147)
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

/// The build plan's Phase 5 acceptance names four anchors by name, not by
/// number: "the DFG, HRD, gatekeeper and hinge annotate at the correct KLIFS
/// positions". A track labelled "KLIFS 45" does not meet that; a reader cannot
/// act on a bare number.
///
/// Every expected value here comes from KLIFS itself, via
/// `interactions_match_residues` for structure 3878 (CDK2, 1HCK), rather than
/// from memory. Recalling the boundaries got two of them wrong: the alphaC helix
/// is KLIFS 20 to 30, not 17 to 24, and the DFG motif sits inside a FOUR-position
/// region KLIFS calls `xDFG` (80 to 83), where the x is the residue before the
/// aspartate.
@Suite("KLIFS regions")
struct KLIFSRegionTests {

    @Test("The bundled table is the 85-position scheme and names its source")
    func table() throws {
        let store = try FamilyStore()
        #expect(store.klifsRegions.labels.count == 85)
        #expect(store.klifsRegions.provenance.contains("KLIFS"))
        #expect(store.klifsRegions.labels[44] == "GK.45")
        #expect(store.klifsRegions.labels[80] == "xDFG.81")
    }

    @Test("Named regions cover the positions KLIFS assigns them")
    func regions() throws {
        let store = try FamilyStore()
        let regions = store.klifsRegions
        #expect(regions.region(at: KLIFSRegions.gatekeeperPosition) == "GK")
        #expect(regions.positions(in: "hinge") == Array(KLIFSRegions.hingePositions))
        #expect(regions.positions(in: "xDFG") == Array(KLIFSRegions.xDFGPositions))
        // Recalled from memory this was 17 to 24. It is not.
        #expect(regions.positions(in: "\u{03B1}C") == Array(20...30))
        #expect(regions.region(at: 0) == nil)
        #expect(regions.region(at: 86) == nil)
    }

    @Test("CDK2's named anchors land on the residues KLIFS reports for 1HCK")
    func cdk2Anchors() throws {
        let store = try FamilyStore()
        let sequence = try fixture("P24941_CDK2_HUMAN.fasta")
        let result = try store.klifsNumbering(for: sequence)
        let regions = store.klifsRegions

        func residue(labelled label: String) throws -> (index: Int, code: Character) {
            let number = try #require(
                result.numbers.first { $0.label == label },
                "no residue was numbered \(label)")
            return (number.residue, sequence.residues[number.residue].code)
        }

        // KLIFS for 1HCK: GK.45 is Xray 80, a phenylalanine.
        let gatekeeper = try residue(labelled: "GK.45")
        #expect(gatekeeper.index + 1 == 80)
        #expect(gatekeeper.code == "F")

        // hinge.46 to 48 are Xray 81, 82, 83: E, F, L.
        let hinge = try (0..<3).map { try residue(labelled: "hinge.\(46 + $0)") }
        #expect(hinge.map { $0.index + 1 } == [81, 82, 83])
        #expect(String(hinge.map(\.code)) == "EFL")

        // xDFG.81 to 83 are Xray 145, 146, 147: the DFG itself.
        let dfg = try (0..<3).map { try residue(labelled: "xDFG.\(81 + $0)") }
        #expect(dfg.map { $0.index + 1 } == [145, 146, 147])
        #expect(String(dfg.map(\.code)) == "DFG")

        // The named anchors are what the acceptance criterion actually asks
        // for: a reader should not have to know that 45 means gatekeeper.
        let anchors = store.pocketAnchors(result, in: sequence)
        let byName = Dictionary(
            anchors.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byName["Gatekeeper"]?.description == "F80")
        #expect(byName["Hinge"]?.description == "E81 to L83")
        #expect(byName["DFG"]?.description == "D145 to G147")
        #expect(byName["Beta-3 lysine"]?.description == "K33")
        // The DFG anchor is three residues, not the four of KLIFS's xDFG region.
        #expect(byName["DFG"]?.positions.count == 3)

        // The segment is the region name, so the ruler can group by it.
        let numbered = try #require(result.numbers.first { $0.label == "GK.45" })
        #expect(numbered.segment == "GK")
        #expect(regions.region(at: 45) == "GK")
    }
}

@Suite("Numbering with non-canonical residues")
struct NonCanonicalNumberingTests {

    /// Alignment can only run over canonical residues, so the array it indexes
    /// is SHORTER than the sequence whenever an X or any other non-canonical
    /// character is present. Treating one index as the other shifts every
    /// number after the first such character by one, and the resulting track is
    /// exactly the right length, validates cleanly, and labels the wrong
    /// residues. This pins the fix.
    @Test("An X in the sequence does not shift every number after it")
    func nonCanonicalDoesNotShiftNumbering() throws {
        let store = try FamilyStore()
        let clean = try fixture("P24941_CDK2_HUMAN.fasta")

        // Insert an X at position 5 (zero-based 4), before every anchor.
        var letters = Array(clean.letters)
        letters.insert("X", at: 4)
        let spiked = ProteinSequence(
            name: "CDK2 with an X", letters: String(letters),
            source: .fixture(name: "synthetic"))
        #expect(spiked.count == clean.count + 1)

        let before = try store.klifsNumbering(for: clean)
        let after = try store.klifsNumbering(for: spiked)

        func residue(
            _ result: NumberingResult, _ label: String, in sequence: ProteinSequence
        )
            throws -> (position: Int, code: Character)
        {
            let number = try #require(result.numbers.first { $0.label == label })
            return (number.residue + 1, sequence.residues[number.residue].code)
        }

        for label in ["III.17", "GK.45", "xDFG.81"] {
            let original = try residue(before, label, in: clean)
            let spikedHit = try residue(after, label, in: spiked)
            // The residue moved one along, because a character was inserted
            // before it. The IDENTITY must not have changed.
            #expect(
                spikedHit.position == original.position + 1,
                "\(label) moved to \(spikedHit.position), expected \(original.position + 1)")
            #expect(
                spikedHit.code == original.code,
                "\(label) now names \(spikedHit.code) instead of \(original.code)")
        }
    }

    @Test("The track writes labels into the cells they belong to")
    func trackAlignsWithTheSequence() throws {
        let store = try FamilyStore()
        let clean = try fixture("P24941_CDK2_HUMAN.fasta")
        var letters = Array(clean.letters)
        letters.insert("X", at: 4)
        let spiked = ProteinSequence(
            name: "CDK2 with an X", letters: String(letters),
            source: .fixture(name: "synthetic"))

        let result = try store.klifsNumbering(for: spiked)
        let track = try #require(
            FamilyStore.track(result, residueCount: spiked.count, title: "KLIFS"))
        try track.validate(against: spiked)

        guard case .categorical(let labels) = track.values else {
            Issue.record("expected a categorical track")
            return
        }
        // The gatekeeper is CDK2 F80, so F81 once an X is inserted before it.
        let gatekeeper = try #require(result.numbers.first { $0.label == "GK.45" })
        #expect(gatekeeper.residue + 1 == 81)
        #expect(labels[gatekeeper.residue] == "GK")
        #expect(spiked.residues[gatekeeper.residue].code == "F")
    }
}
