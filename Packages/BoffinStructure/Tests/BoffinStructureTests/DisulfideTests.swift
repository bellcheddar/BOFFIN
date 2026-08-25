//  DisulfideTests.swift
//  BoffinStructureTests
//
//  Written against the published facts before the finder, per hard rule 6.
//
//  The fixture set happens to give three different answers, which is why it can
//  test this properly:
//
//  - 6EQE, PETase, has TWO disulfides: Cys203 to Cys239, the one near the
//    active site that is unique to IsPETase, and Cys273 to Cys289. A positive.
//    This test first asserted one bond, on my own recollection rather than on
//    the structure, and the finder disagreed by finding a second at 2.05 A.
//    The finder was right. The rule is to write the test from the published
//    definition first, and it works exactly as well when it is the test that
//    turns out to be wrong: what it must not be is written from the output.
//  - 1HCK, CDK2, has several cysteines and NO disulfides, because it is an
//    intracellular kinase and the cytosol is reducing. A negative that still
//    exercises the whole search: the sulfurs are there, they simply do not pair.
//  - 1UBQ, ubiquitin, has no cysteine at all. A negative that exercises the
//    early exit.
//
//  A detector validated only on the positive would pass while pairing every
//  cysteine it saw. The kinase is the fixture that catches that, and it is the
//  reason the negatives are here rather than as an afterthought.

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

@Suite("Disulfide detection")
struct DisulfideTests {

    @Test("PETase has both of its disulfides, and only those")
    func petaseHasTwoDisulfides() throws {
        let atoms = try store("6eqe.bcif")

        // Four cysteines, all four paired. The premise, asserted: a detector
        // that found two bonds among six cysteines would be a different and
        // much weaker result than one that paired everything available.
        let sulfurs = (0..<atoms.count).filter {
            atoms.atomName[$0] == "SG" && atoms.residueName[$0] == "CYS"
        }
        #expect(sulfurs.count == 4)

        let bonds = DisulfideFinder.find(in: atoms)
        #expect(bonds.count == 2, "PETase has two disulfides and found \(bonds.count)")

        let pairs = Set(bonds.map { [$0.firstNumber, $0.secondNumber] }.map { Set($0) })
        #expect(pairs.contains(Set([203, 239])), "the active-site disulfide is missing")
        #expect(pairs.contains(Set([273, 289])), "the second disulfide is missing")
        #expect(bonds.filter(\.isIntrachain).count == bonds.count)

        // Real S-S bonds, not merely nearby sulfurs. 2.03 A is the canonical
        // length, and both of these measure inside 0.03 A of it. Checking the
        // geometry separately from the identity matters: a pair can be the
        // right two residues at a distance that is not a bond.
        for bond in bonds {
            #expect(
                abs(bond.distance - 2.03) < 0.15,
                "S-S measured \(bond.distance) A, which is not a disulfide bond length")
        }
    }

    @Test("Each pair constrains the span between its two cysteines")
    func petaseSpansAreTheConstrainedRegions() throws {
        let atoms = try store("6eqe.bcif")
        let bonds = DisulfideFinder.find(in: atoms)
        let spans = Set(bonds.compactMap(\.span))
        // This is what the Boundary tab enforces: a truncation inside either
        // range separates a covalent bond, and the protein will not fold.
        #expect(spans == Set([203...239, 273...289]))
    }

    @Test("CDK2 has cysteines and no disulfides")
    func kinaseHasNoDisulfides() throws {
        let atoms = try store("1hck.bcif")

        // The premise of the test, asserted rather than assumed: if this
        // structure had no SG atoms then finding no bonds would prove nothing
        // about the pairing logic.
        let sulfurs = (0..<atoms.count).filter {
            atoms.atomName[$0] == "SG" && atoms.residueName[$0] == "CYS"
        }
        // Three: Cys118, Cys177 and Cys191. Enough to exercise the pairing
        // search rather than the early exit, which is the whole point of using
        // this fixture as the negative instead of ubiquitin alone.
        #expect(sulfurs.count == 3, "expected three cysteines in CDK2, found \(sulfurs.count)")

        let bonds = DisulfideFinder.find(in: atoms)
        #expect(
            bonds.isEmpty,
            "CDK2 is intracellular and has no disulfides, but \(bonds.count) were found")
    }

    @Test("Ubiquitin has no cysteine at all")
    func ubiquitinHasNoCysteine() throws {
        let atoms = try store("1ubq.bcif")
        let sulfurs = (0..<atoms.count).filter { atoms.residueName[$0] == "CYS" }
        #expect(sulfurs.isEmpty, "ubiquitin has no cysteine")
        #expect(DisulfideFinder.find(in: atoms).isEmpty)
    }

    @Test("A sulfur is never given two partners")
    func oneBondPerSulfur() {
        // Three sulfurs in a line, each 2.1 A from the next. Naive thresholding
        // returns two bonds sharing the middle atom, which is chemically
        // impossible: sulfur forms one S-S bond. Real structures produce this
        // arrangement through altlocs and crowded sites, so it is not a
        // contrived case, it is the one the greedy matching exists for.
        var atoms = AtomStore()
        for (index, x) in [Float(0), 2.1, 4.2].enumerated() {
            atoms.append(
                x: x, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
                authorNumber: 10 + index, chainID: "A", bFactor: 20, occupancy: 1,
                altLoc: "", isHeteroatom: false, model: 1)
        }

        let bonds = DisulfideFinder.find(in: atoms)
        #expect(bonds.count == 1, "one sulfur was given two partners")
        // The shortest available pair wins; here both are 2.1, so the assertion
        // is on the count and on each residue appearing at most once.
        let residues = bonds.flatMap { [$0.firstNumber, $0.secondNumber] }
        #expect(Set(residues).count == residues.count)
    }

    @Test("Alternate locations of one cysteine are not a bond to itself")
    func altlocsCollapseToOneSulfur() {
        // A cysteine modelled in two conformations has two SG atoms at the same
        // residue, about 1 A apart. Counting both invents a disulfide from a
        // residue to itself, which would then be a construct constraint over a
        // span of zero residues: nonsense that looks like data.
        var atoms = AtomStore()
        atoms.append(
            x: 0, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
            authorNumber: 52, chainID: "A", bFactor: 20, occupancy: 0.6,
            altLoc: "A", isHeteroatom: false, model: 1)
        atoms.append(
            x: 1.8, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
            authorNumber: 52, chainID: "A", bFactor: 20, occupancy: 0.4,
            altLoc: "B", isHeteroatom: false, model: 1)

        #expect(DisulfideFinder.find(in: atoms).isEmpty)
    }

    @Test("An NMR ensemble is not searched across its models")
    func modelsAreNotMixed() {
        // The same cysteine pair in two models sits at nearly the same place,
        // so searching every model as one bag of atoms pairs a sulfur with its
        // own image in another model at a distance of almost zero. That would
        // also be rejected by the minimum-distance floor, so the case that
        // actually bites is a sulfur in model 1 landing 2.1 A from a DIFFERENT
        // residue's sulfur in model 2, which is what this builds.
        var atoms = AtomStore()
        atoms.append(
            x: 0, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
            authorNumber: 10, chainID: "A", bFactor: 20, occupancy: 1,
            altLoc: "", isHeteroatom: false, model: 1)
        atoms.append(
            x: 2.1, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
            authorNumber: 40, chainID: "A", bFactor: 20, occupancy: 1,
            altLoc: "", isHeteroatom: false, model: 2)

        #expect(
            DisulfideFinder.find(in: atoms).isEmpty,
            "a bond was formed between two different models of the protein")
    }

    @Test("Nonsensically short contacts are rejected as broken input")
    func impossiblyShortContactsAreRejected() {
        // 0.8 A is not a strained disulfide. It is an unmerged altloc, a
        // duplicated atom, or a file that should not be trusted, and accepting
        // it would put a fabricated hard constraint in front of a user.
        var atoms = AtomStore()
        for (index, x) in [Float(0), 0.8].enumerated() {
            atoms.append(
                x: x, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
                authorNumber: 10 + index, chainID: "A", bFactor: 20, occupancy: 1,
                altLoc: "", isHeteroatom: false, model: 1)
        }
        #expect(DisulfideFinder.find(in: atoms).isEmpty)
    }

    @Test("An inter-chain disulfide is found but does not constrain a construct")
    func interchainPairsAreNotBoundaryConstraints() {
        // A real bond and a different problem: it says something about the
        // assembly, not about where this chain may be cut. Reporting it as a
        // span in one chain's numbering would be meaningless.
        var atoms = AtomStore()
        atoms.append(
            x: 0, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
            authorNumber: 10, chainID: "A", bFactor: 20, occupancy: 1,
            altLoc: "", isHeteroatom: false, model: 1)
        atoms.append(
            x: 2.05, y: 0, z: 0, element: "S", atomName: "SG", residueName: "CYS",
            authorNumber: 10, chainID: "B", bFactor: 20, occupancy: 1,
            altLoc: "", isHeteroatom: false, model: 1)

        let bonds = DisulfideFinder.find(in: atoms)
        #expect(bonds.count == 1, "the bond is real and should be found")
        #expect(bonds[0].isIntrachain == false)
        #expect(bonds[0].span == nil, "an inter-chain pair has no span in one chain")
    }
}
