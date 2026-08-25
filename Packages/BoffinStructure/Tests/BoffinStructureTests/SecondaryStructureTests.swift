//  SecondaryStructureTests.swift
//  BoffinStructureTests
//
//  Checked against what is known about the fixtures rather than against another
//  implementation. Ubiquitin's fold is in every textbook: a mixed alpha/beta
//  protein with one long helix over a four-stranded sheet, and roughly a third
//  of it helical.

import Foundation
import Testing

@testable import BoffinStructure

private func structure(_ name: String) throws -> AtomStore {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures/\(name)")
    return try AtomStore.from(try BinaryCIF.decode(Data(contentsOf: url)))
}

@Suite("Secondary structure from coordinates")
struct SecondaryStructureTests {

    private func assign(_ name: String, _ chain: String = "A") throws -> [DSSPState] {
        SecondaryStructureAssigner.assign(try structure(name), chain: chain)
    }

    @Test("Every residue of the chain gets a state")
    func coverage() throws {
        let states = try assign("1ubq.bcif")
        #expect(states.count == 76, "ubiquitin has 76 residues, got \(states.count)")
        #expect(!states.contains(.unknown), "a complete backbone should be assignable")
    }

    /// Ubiquitin is a beta-grasp fold: a mixed protein, not an all-helix or
    /// all-sheet one. Its long helix runs residues 23 to 34.
    @Test("Ubiquitin comes out mixed, with its helix in the right place")
    func ubiquitinFold() throws {
        let states = try assign("1ubq.bcif")
        let helix = states.count { $0.threeState == "H" }
        let strand = states.count { $0.threeState == "E" }

        #expect(helix > 8, "only \(helix) helical residues in ubiquitin")
        #expect(strand > 8, "only \(strand) strand residues in ubiquitin")
        #expect(helix < states.count / 2, "ubiquitin is not mostly helix")

        // The alpha helix spans residues 23 to 34 (one-based). Allowing for the
        // ends being ragged, most of that window must be helical.
        let window = states[22..<34]
        let helicalInWindow = window.count { $0.threeState == "H" }
        #expect(
            helicalInWindow >= 8,
            "the main helix is not where it should be: \(helicalInWindow) of 12")

        // And the N-terminal hairpin, residues 2 to 17, is mostly strand.
        let hairpin = states[1..<17]
        #expect(hairpin.count { $0.threeState == "E" } >= 6)
    }

    /// CDK2 is a kinase: an N-lobe that is mostly sheet and a C-lobe that is
    /// mostly helix. The whole protein is helix-rich.
    @Test("A kinase comes out helix-rich, as its fold requires")
    func kinaseFold() throws {
        let states = try assign("1hck.bcif")
        let helix = states.count { $0.threeState == "H" }
        let strand = states.count { $0.threeState == "E" }
        #expect(helix > strand, "a kinase should be helix-rich: \(helix) vs \(strand)")
        #expect(strand > 15, "the N-lobe sheet is missing: \(strand) strand residues")
    }

    /// Proline cannot donate a hydrogen bond: it has no amide hydrogen. Missing
    /// this makes helices one residue too long wherever a proline caps one,
    /// which is most of them.
    @Test("Proline never donates a hydrogen bond")
    func prolineCannotDonate() throws {
        let store = try structure("1ubq.bcif")
        let residues = SecondaryStructureAssigner.backbones(store, chain: "A")
        let prolines = residues.indices.filter { residues[$0].residueName == "PRO" }
        #expect(!prolines.isEmpty, "ubiquitin has prolines")
        for proline in prolines {
            for acceptor in residues.indices {
                #expect(
                    !SecondaryStructureAssigner.hasHydrogenBond(
                        residues, donor: proline, acceptor: acceptor),
                    "a proline donated a hydrogen bond")
            }
        }
    }

    /// An incomplete backbone is `.unknown`, not `.coil`. Coil is a statement
    /// about the structure; unknown is a statement about the data, and a chain
    /// break silently labelled coil is a chain break that trains a model.
    @Test("A missing backbone atom is unknown rather than coil")
    func incompleteBackbone() {
        var store = AtomStore()
        // One residue with only an alpha carbon.
        store.append(
            x: 0, y: 0, z: 0, element: "C", atomName: "CA", residueName: "ALA",
            authorNumber: 1, chainID: "A", bFactor: 0, occupancy: 1, altLoc: "",
            isHeteroatom: false, model: 1)
        store.append(
            x: 3.8, y: 0, z: 0, element: "C", atomName: "CA", residueName: "ALA",
            authorNumber: 2, chainID: "A", bFactor: 0, occupancy: 1, altLoc: "",
            isHeteroatom: false, model: 1)
        let states = SecondaryStructureAssigner.assign(store, chain: "A")
        #expect(states.count == 2)
        #expect(states.allSatisfy { $0 == .unknown })
    }

    @Test("An unknown chain yields nothing rather than a wrong answer")
    func unknownChain() throws {
        #expect(try assign("1ubq.bcif", "Z").isEmpty)
    }

    @Test("The three-state collapse is the standard one")
    func threeStateCollapse() {
        #expect(DSSPState.alphaHelix.threeState == "H")
        #expect(DSSPState.threeTenHelix.threeState == "H")
        #expect(DSSPState.piHelix.threeState == "H")
        #expect(DSSPState.betaStrand.threeState == "E")
        #expect(DSSPState.betaBridge.threeState == "E")
        #expect(DSSPState.turn.threeState == "C")
        #expect(DSSPState.bend.threeState == "C")
        #expect(DSSPState.coil.threeState == "C")
        #expect(DSSPState.unknown.threeState == "-")
    }
}
