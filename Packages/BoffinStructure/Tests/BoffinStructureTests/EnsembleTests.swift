//  EnsembleTests.swift
//  BoffinStructureTests
//
//  An NMR ensemble is many superimposed copies of one protein, and BOFFIN
//  deliberately analyses ONE of them: loading twenty at once renders as a
//  single very badly resolved structure, and every geometric measurement would
//  be taken across copies that are not in contact.
//
//  That choice was documented and untested, because **no fixture had more than
//  one model**. 1XQ8 was recorded as the ensemble fixture and is not one: the
//  authoritative mmCIF has 2,017 ATOM records all at model 1. Solution NMR does
//  not imply an ensemble, and that inference is how the claim got into the
//  manifest.
//
//  1L2Y is a real one: Trp-cage, 38 models, 11,552 atom rows.

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

private func file(_ name: String) throws -> BinaryCIFFile {
    try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name)))
}

@Suite("NMR ensembles")
struct EnsembleTests {

    @Test("1L2Y really holds 38 models")
    func trpCageIsAnEnsemble() throws {
        // The premise, asserted against the raw table rather than the parsed
        // store: if this fixture stops being an ensemble, every test below
        // becomes vacuous while still passing.
        let site = try #require(try file("1l2y.bcif")["_atom_site"])
        #expect(site.rowCount == 11_552)

        let column = try #require(site.columns["pdbx_PDB_model_num"])
        var models = Set<String>()
        for row in 0..<site.rowCount {
            if let value = column.string(row) { models.insert(value) }
        }
        #expect(models.count == 38, "1L2Y deposits 38 models, found \(models.count)")
    }

    @Test("Only one model is loaded, and that is a decision rather than an accident")
    func oneModelIsTaken() throws {
        // 11,552 rows in, 304 atoms out: exactly one model's worth. The point
        // of the test is that the ratio is exact, so a parser that started
        // concatenating models would fail here rather than quietly producing a
        // structure whose every distance measurement spans two copies.
        let atoms = try AtomStore.from(try file("1l2y.bcif"))
        #expect(atoms.count == 304, "expected one model's atoms, got \(atoms.count)")
        #expect(atoms.models == [1], "the store should hold exactly the model it took")
        #expect(11_552 / atoms.count == 38)
    }

    @Test("A specific model can be asked for, and differs from the first")
    func anotherModelCanBeTaken() throws {
        // The parameter exists and is not decorative. Model 7 has the same
        // atoms in different places, so the counts match and the coordinates
        // must not: an ensemble whose models were identical would mean the
        // selection was being ignored.
        let first = try AtomStore.from(try file("1l2y.bcif"), model: 1)
        let seventh = try AtomStore.from(try file("1l2y.bcif"), model: 7)
        #expect(first.count == seventh.count, "every model holds the same atoms")

        let moved = zip(first.x, seventh.x).contains { abs($0 - $1) > 0.01 }
        #expect(moved, "model 7 is identical to model 1, so the selection did nothing")
    }

    @Test("1XQ8 is a single-model NMR structure, which is why it cannot test this")
    func alphaSynucleinIsNotAnEnsemble() throws {
        // Kept as the record of a claim that was wrong for four months. The
        // manifest called this the ensemble fixture because the entry is
        // solution NMR, and the two are not the same thing.
        let site = try #require(try file("1xq8.bcif")["_atom_site"])
        #expect(site.rowCount == 2_017)
        let atoms = try AtomStore.from(try file("1xq8.bcif"))
        #expect(atoms.count == site.rowCount, "nothing was dropped: there is only one model")
    }
}
