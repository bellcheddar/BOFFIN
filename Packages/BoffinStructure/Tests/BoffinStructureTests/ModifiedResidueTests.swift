//  ModifiedResidueTests.swift
//  BoffinStructureTests
//
//  Selenomethionine is how a great many structures get phased, so MSE is one of
//  the commonest residues in the PDB that is not one of the twenty. It is
//  deposited as HETATM, and a viewer that treats HETATM as "not polymer" drops
//  a methionine out of the middle of a chain: `polymer` misses it, `byres
//  (polymer within 5 of organic)` returns a pocket with a hole in it, and the
//  cartoon breaks where the residue should be.
//
//  `SelectionEvaluator` handles this deliberately. `polymerResidues` carries
//  MSE alongside SEC, PYL, HYP, SEP, TPO, PTR, CSO and CME, and there is
//  explicit logic to accept MSE even when the record says HETATM.
//
//  **None of it had ever run.** The fixture credited with "non-standard
//  residues" was 1E8A, described in the manifest as selenomethionine
//  substituted. It is human S100A12, with no MSE at all, so the path was
//  written correctly and exercised never. 1A8O is a real one.

import Foundation
import Testing

@testable import BoffinStructure

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures")
}

private func store(_ name: String) throws -> AtomStore {
    try AtomStore.from(try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name))))
}

@Suite("Modified residues")
struct ModifiedResidueTests {

    @Test("1A8O carries selenomethionine, recorded as HETATM")
    func selenomethioninePresentAsHeteroatom() throws {
        // The premise, asserted: both that MSE is there and that it is HETATM,
        // because it is the HETATM part that the special case exists for. A
        // fixture whose MSE were plain ATOM records would test nothing.
        let atoms = try store("1a8o.bcif")
        let mse = (0..<atoms.count).filter { atoms.residueName[$0] == "MSE" }
        #expect(mse.count == 32, "expected 32 MSE atoms, found \(mse.count)")
        #expect(
            mse.allSatisfy { atoms.isHeteroatom[$0] },
            "the special case is for MSE recorded as HETATM, and these are not")

        // And the selenium itself, which is what makes it selenomethionine
        // rather than an ordinary modified residue.
        let selenium = (0..<atoms.count).filter { atoms.element[$0].uppercased() == "SE" }
        #expect(selenium.count == 4)
    }

    @Test("Selenomethionine counts as polymer despite being a heteroatom")
    func selenomethionineIsPolymer() throws {
        // The behaviour the special case buys. Without it, four methionines
        // vanish from the middle of a chain: the cartoon breaks where they
        // should be and any pocket selection returns a hole rather than an
        // error.
        let atoms = try store("1a8o.bcif")
        let polymer = SelectionEvaluator.evaluate(.category(.polymer), in: atoms).indices
        let mse = (0..<atoms.count).filter { atoms.residueName[$0] == "MSE" }

        #expect(
            mse.allSatisfy { polymer.contains($0) },
            "selenomethionine was excluded from the polymer, so this chain has holes in it")
        #expect(polymer.count > mse.count, "the selection is more than just the MSE")
    }

    @Test("Ordinary heteroatoms are still not polymer")
    func waterAndLigandsStayOut() throws {
        // The other half: the MSE exception must not have widened into "all
        // heteroatoms are polymer", which would pull every water into a pocket
        // selection and look like a much larger binding site.
        let atoms = try store("1a8o.bcif")
        let polymer = SelectionEvaluator.evaluate(.category(.polymer), in: atoms).indices
        let water = (0..<atoms.count).filter { atoms.residueName[$0] == "HOH" }
        #expect(!water.isEmpty, "1A8O has waters, or this test proves nothing")
        #expect(
            water.allSatisfy { !polymer.contains($0) },
            "water was counted as polymer")
    }

    @Test("1E8A is not the selenomethionine fixture it was recorded as")
    func s100a12HasNoSelenomethionine() throws {
        // Kept as the record of a claim that stood for months. The manifest
        // called 1E8A "selenomethionine-substituted" and credited it with
        // non-standard residues; the entry is human S100A12 and has neither.
        let atoms = try store("1e8a.bcif")
        #expect(
            !(0..<atoms.count).contains { atoms.residueName[$0] == "MSE" },
            "1E8A has no MSE, which is why it could never have tested this")

        // What it does have, and is now used for.
        let calcium = (0..<atoms.count).filter { atoms.residueName[$0] == "CA" }
        #expect(!calcium.isEmpty, "1E8A is a calcium-binding protein")
    }
}
