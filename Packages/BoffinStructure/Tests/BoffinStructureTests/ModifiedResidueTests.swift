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

@Suite("Modified residues as heteroatoms")
struct ModifiedHeteroatomTests {

    /// A chain of three residues where the middle one is modified and, as the
    /// PDB records it, a HETATM.
    private func chain(middle: String, heteroatom: Bool) -> AtomStore {
        var atoms = AtomStore()
        let residues = [("SER", false), (middle, heteroatom), ("GLY", false)]
        for (index, entry) in residues.enumerated() {
            atoms.append(
                x: Float(index) * 3.8, y: 0, z: 0, element: "C", atomName: "CA",
                residueName: entry.0, authorNumber: index + 1, chainID: "A",
                bFactor: 20, occupancy: 1, altLoc: "", isHeteroatom: entry.1, model: 1)
        }
        return atoms
    }

    @Test("Phosphoserine stays in the chain, and the others with it")
    func modifiedResiduesSurviveTheHeteroatomFlag() throws {
        // The bug this covers: the exception was `== "MSE"`, so
        // selenomethionine was rescued and nothing else was. SEP, TPO and PTR
        // are deposited as HETATM and are the entire point of a
        // kinase-substrate structure, so a phosphopeptide lost its
        // phosphoresidues from every polymer selection: the cartoon breaks at
        // the modified residue and a pocket returns a hole exactly where the
        // chemistry is.
        for name in ["SEP", "TPO", "PTR", "CSO", "CME", "SEC", "PYL", "HYP", "MSE"] {
            let atoms = chain(middle: name, heteroatom: true)
            let polymer = SelectionEvaluator.evaluate(.category(.polymer), in: atoms).indices
            #expect(
                polymer.count == 3,
                "\(name) was dropped from the chain, leaving \(polymer.count) of 3 residues")
        }
    }

    @Test("A free amino acid ligand is still not part of the chain")
    func standardResiduesAsHeteroatomsStayOut() throws {
        // The other side, and why the exception is a named set rather than
        // "any name in polymerResidues". A free alanine or glycine bound in a
        // site is deposited as HETATM and is a LIGAND. Accepting every polymer
        // name as HETATM would quietly pull it into the protein, which is the
        // opposite error and just as invisible.
        for name in ["ALA", "GLY", "SER", "HIS"] {
            let atoms = chain(middle: name, heteroatom: true)
            let polymer = SelectionEvaluator.evaluate(.category(.polymer), in: atoms).indices
            #expect(
                polymer.count == 2,
                "a free \(name) ligand was counted as part of the chain")
        }
    }

    @Test("The two sets say what they mean")
    func setsAreConsistent() {
        // Every modified residue that takes the HETATM exception must also be
        // a polymer residue, or the exception admits something the ordinary
        // rule would reject.
        #expect(
            SelectionEvaluator.modifiedPolymerResidues
                .isSubset(of: SelectionEvaluator.polymerResidues))
        // And none of the standard twenty may be in it.
        #expect(
            SelectionEvaluator.modifiedPolymerResidues.isDisjoint(
                with: ["ALA", "ARG", "ASN", "ASP", "CYS", "GLN", "GLU", "GLY", "HIS", "ILE"]))
    }
}

@Suite("Interaction assumptions say what was done")
struct AssumptionsHonestyTests {

    /// A structure carrying explicit hydrogens.
    ///
    /// PETase has 2,102 of them. The profiler's hydrogen-bearing branch had
    /// never run: the only profiling test uses CDK2, which has none, so the
    /// statement shown for a structure WITH hydrogens went unread for months.
    private func petase() throws -> AtomStore {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/structures/6eqe.bcif")
        return try AtomStore.from(try BinaryCIF.decode(Data(contentsOf: url)))
    }

    @Test("PETase really carries hydrogens, or this proves nothing")
    func petaseHasHydrogens() throws {
        let atoms = try petase()
        let hydrogens = (0..<atoms.count).filter { atoms.element[$0].uppercased() == "H" }
        #expect(hydrogens.count > 2000, "found \(hydrogens.count) hydrogens")
    }

    @Test("The statement does not claim hydrogens were used, because they are not")
    func statementDoesNotOverclaim() {
        // This is the honesty mechanism, so it is the one string in the app
        // that must never overclaim. It said explicit hydrogens "were used for
        // donor geometry where present" and nothing uses them: the criterion is
        // heavy-atom distance alone, and `hydrogenBondAngle` is read nowhere.
        let withHydrogens = InteractionAssumptions(hasExplicitHydrogens: true, pH: 7.4)
        let statement = withHydrogens.statement

        #expect(statement.contains("NOT used"), "the statement must say they are unused")
        #expect(
            !statement.contains("were used for donor geometry"),
            "the overclaiming sentence is back")
        #expect(statement.contains("heavy-atom distance"))
    }

    @Test("Both statements name the pH and neither is silent")
    func bothBranchesSayEnough() {
        // The branch without hydrogens was the tested one and stays as it was.
        for hydrogens in [true, false] {
            let statement = InteractionAssumptions(
                hasExplicitHydrogens: hydrogens, pH: 7.4
            ).statement
            #expect(statement.contains("7.4"), "the assumed pH is part of the assumption")
            #expect(statement.count > 80, "a one-line disclaimer is not an assumption statement")
        }
    }
}
