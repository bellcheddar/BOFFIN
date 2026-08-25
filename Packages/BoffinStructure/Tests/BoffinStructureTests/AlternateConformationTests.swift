//  AlternateConformationTests.swift
//  BoffinStructureTests
//
//  A residue refined in two or three conformations is written as two or three
//  copies of its atoms, each with an altloc code and a partial occupancy. They
//  are alternative models of ONE residue, and every analysis that walks the
//  atom list has to decide which copy it means.
//
//  This suite exists because one of them was deciding by accident. The fixture
//  that catches it is PETase, which the manifest describes as the catalytic
//  triad fixture: 709 of its 4,596 atoms carry an altloc, and 25 residues have
//  alternate CA positions. 1E8A, whose manifest entry claims it exercises
//  alternate locations, has none at all.

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

@Suite("Alternate conformations")
struct AlternateConformationTests {

    @Test("PETase really does carry alternate conformations")
    func petaseHasAltlocs() throws {
        // The premise, asserted. Every test below is vacuous if this fixture
        // stops having altlocs, and a suite that silently becomes vacuous is
        // worse than no suite.
        let atoms = try store("6eqe.bcif")
        #expect(atoms.hasAlternateConformations)
        let withAlt = (0..<atoms.count).filter { !atoms.altLoc[$0].isEmpty }
        #expect(withAlt.count > 500, "expected hundreds of altloc atoms, found \(withAlt.count)")
    }

    @Test("Ubiquitin carries none, so the fast path is exercised too")
    func ubiquitinHasNoAltlocs() throws {
        let atoms = try store("1ubq.bcif")
        #expect(!atoms.hasAlternateConformations)
        // With nothing to choose between, every atom survives and the
        // dictionary is never built.
        #expect(atoms.primaryConformationIndices().count == atoms.count)
    }

    @Test("One atom per residue and name survives, and it is the major conformer")
    func majorConformerWins() throws {
        let atoms = try store("6eqe.bcif")
        let kept = atoms.primaryConformationIndices()
        let keptSet = Set(kept)

        // No duplicates: at most one copy of each (chain, residue, atom name).
        struct Key: Hashable {
            let chain: String
            let number: Int
            let atom: String
        }
        var seen = Set<Key>()
        for index in kept {
            let key = Key(
                chain: atoms.chainID[index], number: atoms.authorNumber[index],
                atom: atoms.atomName[index])
            #expect(
                seen.insert(key).inserted,
                "\(key.chain)/\(key.number)/\(key.atom) survived more than once")
        }

        // And the survivor is the highest-occupancy copy. This is the assertion
        // that would have failed before the fix: the old rule was last-wins in
        // file order, which is altloc code order, and on residue 53 that takes
        // the 0.29 copy over two at 0.35.
        var byKey: [Key: [Int]] = [:]
        for index in 0..<atoms.count where !atoms.altLoc[index].isEmpty {
            let key = Key(
                chain: atoms.chainID[index], number: atoms.authorNumber[index],
                atom: atoms.atomName[index])
            byKey[key, default: []].append(index)
        }
        var checked = 0
        for (_, candidates) in byKey where candidates.count > 1 {
            let survivor = candidates.filter { keptSet.contains($0) }
            #expect(survivor.count == 1)
            guard let winner = survivor.first else { continue }
            let best = candidates.map { atoms.occupancy[$0] }.max() ?? 0
            #expect(
                atoms.occupancy[winner] == best,
                "kept a \(atoms.occupancy[winner]) copy when \(best) was available")
            checked += 1
        }
        #expect(checked > 100, "only \(checked) alternate sites were checked")
    }

    @Test("Ties go to the alphabetically first code, deterministically")
    func tiesAreBrokenDeterministically() {
        // Residue 53 of PETase has two copies at 0.35 and one at 0.29. A tie
        // has to resolve the same way every run or two exports of one structure
        // disagree, which is worse than either answer.
        var atoms = AtomStore()
        for (code, occupancy) in [("B", Float(0.5)), ("A", Float(0.5))] {
            atoms.append(
                x: code == "A" ? 0 : 10, y: 0, z: 0, element: "C", atomName: "CA",
                residueName: "ALA", authorNumber: 1, chainID: "A", bFactor: 20,
                occupancy: occupancy, altLoc: code, isHeteroatom: false, model: 1)
        }
        let kept = atoms.primaryConformationIndices()
        #expect(kept.count == 1)
        // 'A' wins even though 'B' was written first in this store.
        #expect(atoms.altLoc[kept[0]] == "A")
        #expect(atoms.x[kept[0]] == 0)
    }

    @Test("A backbone is never assembled from two different conformers")
    func backbonesComeFromOneConformer() {
        // The failure this guards is worse than picking the minor copy: with
        // last-wins there was nothing stopping the N coming from conformer A
        // and the CA from conformer B. Those are two different molecules, and
        // a peptide built from both has bond lengths and angles that exist in
        // neither.
        //
        // Conformer A is placed as a real residue; conformer B is displaced far
        // enough that any mixing shows up as an impossible N to CA distance.
        var atoms = AtomStore()
        func add(_ name: String, _ x: Float, _ code: String, _ occupancy: Float) {
            atoms.append(
                x: x, y: 0, z: 0, element: name == "N" ? "N" : "C", atomName: name,
                residueName: "ALA", authorNumber: 1, chainID: "A", bFactor: 20,
                occupancy: occupancy, altLoc: code, isHeteroatom: false, model: 1)
        }
        // Conformer A, the major one, with a real 1.46 A N to CA bond.
        add("N", 0.00, "A", 0.7)
        add("CA", 1.46, "A", 0.7)
        // Conformer B, minor, twenty angstroms away.
        add("N", 20.00, "B", 0.3)
        add("CA", 21.46, "B", 0.3)

        let backbones = SecondaryStructureAssigner.backbones(atoms, chain: "A")
        guard let residue = backbones.first,
            let nitrogen = residue.nitrogen,
            let alpha = residue.alpha
        else {
            Issue.record("no backbone was built at all")
            return
        }

        let dx = alpha.x - nitrogen.x
        #expect(
            abs(dx - 1.46) < 0.01,
            "N and CA came from different conformers: they are \(dx) A apart")
        // And it is the major conformer, not the minor one.
        #expect(abs(nitrogen.x) < 0.01, "the minor conformer was used")
    }

    @Test("`alt` selects by conformation, and `alt ''` selects the unambiguous part")
    func selectionLanguageUnderstandsAltloc() throws {
        let atoms = try store("6eqe.bcif")

        let a = try SelectionParser.parse("alt A")
        let inA = SelectionEvaluator.evaluate(a, in: atoms).indices
        #expect(!inA.isEmpty)
        #expect(inA.allSatisfy { atoms.altLoc[$0] == "A" })

        // The unambiguous part: atoms with no altloc at all. This is the more
        // common question and there would be no way to ask it otherwise.
        let plain = try SelectionParser.parse("alt ''")
        let unambiguous = SelectionEvaluator.evaluate(plain, in: atoms).indices
        #expect(unambiguous.allSatisfy { atoms.altLoc[$0].isEmpty })
        #expect(
            unambiguous.count + (0..<atoms.count).filter { !atoms.altLoc[$0].isEmpty }.count
                == atoms.count)

        // Codes are case sensitive: a file may use 'a' and 'A' for different
        // conformations, so uppercasing the way `resn` and `elem` do would
        // merge two distinct answers.
        let lower = try SelectionParser.parse("alt a")
        #expect(SelectionEvaluator.evaluate(lower, in: atoms).indices.isEmpty)
    }
}
