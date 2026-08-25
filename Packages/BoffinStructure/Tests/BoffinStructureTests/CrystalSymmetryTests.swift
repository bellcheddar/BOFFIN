//  CrystalSymmetryTests.swift
//  BoffinStructureTests

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

@Suite("Crystal symmetry")
struct CrystalSymmetryTests {

    @Test("Ubiquitin is P 21 21 21 with a real cell")
    func ubiquitinIsCrystallographic() throws {
        // 1UBQ's published cell: a 50.84, b 42.77, c 28.95, all angles 90.
        let symmetry = try #require(CrystalSymmetry.read(from: try file("1ubq.bcif")))
        #expect(symmetry.isCrystallographic)
        #expect(symmetry.spacegroup == "P 21 21 21")
        #expect(abs(symmetry.a - 50.84) < 0.1)
        #expect(abs(symmetry.b - 42.77) < 0.1)
        #expect(abs(symmetry.c - 28.95) < 0.1)
        #expect(abs(symmetry.alpha - 90) < 0.01)
        #expect(symmetry.refusal == nil, "a crystal structure must not be refused")
    }

    @Test("An NMR ensemble has no cell, and says so as a fact")
    func nmrHasNoCell() throws {
        // 1XQ8 is alpha-synuclein by NMR. There is no lattice, so there are no
        // symmetry mates: that is a fact about the structure, not a failure,
        // and the wording has to make that clear or a user goes looking for a
        // bug in an app that is working.
        let symmetry = CrystalSymmetry.read(from: try file("1xq8.bcif"))
        if let symmetry {
            #expect(!symmetry.isCrystallographic, "an NMR ensemble has no unit cell")
            let refusal = try #require(symmetry.refusal)
            #expect(!refusal.lowercased().contains("could not"))
            #expect(!refusal.lowercased().contains("fail"))
            #expect(refusal.contains("no unit cell"))
        }
        // A missing category entirely is also a valid answer for such an entry,
        // and is a different fact from a present-but-empty one.
    }

    @Test("A present but empty cell is not a crystal")
    func emptyCellIsNotACrystal() {
        // The case that makes the presence test wrong: enough tools write the
        // categories with zeroes for a non-crystallographic entry that testing
        // for the category would report every predicted model as a crystal.
        let empty = CrystalSymmetry(
            spacegroup: "P 1", a: 0, b: 0, c: 0, alpha: 0, beta: 0, gamma: 0)
        #expect(!empty.isCrystallographic)
        #expect(empty.refusal != nil)
    }

    @Test("A partial cell is not a crystal either")
    func partialCellIsNotACrystal() {
        // Two edges and no third is not a cell. Accepting it would hand the
        // viewer a lattice it cannot build and turn a clear refusal into an
        // obscure failure further down.
        let partial = CrystalSymmetry(
            spacegroup: "P 1", a: 50, b: 40, c: 0, alpha: 90, beta: 90, gamma: 90)
        #expect(!partial.isCrystallographic)
    }
}
