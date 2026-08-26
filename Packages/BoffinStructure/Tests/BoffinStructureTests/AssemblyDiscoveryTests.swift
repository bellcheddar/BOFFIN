//  AssemblyDiscoveryTests.swift
//  BoffinStructureTests
//
//  What the entry says about its own biological assemblies.
//
//  The deposited coordinates are the ASYMMETRIC UNIT, a crystallographic
//  convenience that is frequently not the molecule. A dimer with one chain in
//  the asymmetric unit looks like a monomer until the assembly is built, which
//  is a picture of the wrong protein rather than an incomplete one.
//
//  There are two halves to that, and only one of them can be tested here.
//
//  **Discovery** is reading what the entry declares, from
//  `_pdbx_struct_assembly` in the file BOFFIN parses. That is what this suite
//  covers, against the real declarations of the golden fixtures.
//
//  **Construction** is Mol* rebuilding the structure from those declarations,
//  and it cannot be tested with this fixture set at all, because **every
//  fixture's declared assembly already equals its asymmetric unit**:
//
//      1UBQ  declares 1 chain, ASU has 1        6EQE  1 and 1
//      1HCK  declares 1 chain, ASU has 1        1XQ8  1 and 1
//      2RH1  declares 1 chain, ASU has 1        7K00  56 and 56
//      1E8A  declares 2 chains, ASU has 2 (A and B)
//
//  So building the assembly is a no-op on all seven, and an earlier UI test
//  asserting construction was deleted rather than tuned because there was
//  nothing meaningful for it to assert. Closing that gap needs a fixture whose
//  assembly genuinely differs from its deposited coordinates, which is recorded
//  in the roadmap rather than papered over here.

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

private func numbering(_ name: String) throws -> EntryNumbering {
    EntryNumbering.from(try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name))))
}

@Suite("Assembly discovery")
struct AssemblyDiscoveryTests {

    @Test("1E8A declares a dimer")
    func selenomethionineDeclaresADimer() throws {
        // The one fixture whose assembly is not a monomer. Its chain count is a
        // fact in the deposited file, so this fails if the category is read
        // from the wrong column or the count is parsed as a chain identifier.
        let entry = try numbering("1e8a.bcif")
        let assembly = try #require(entry.assemblies.first)
        #expect(entry.assemblies.count == 1)
        #expect(assembly.id == "1")
        #expect(assembly.chainCount == 2, "1E8A declares a dimer")
    }

    @Test("The ribosome declares all 56 of its chains")
    func ribosomeDeclaresEveryChain() throws {
        // The opposite end of the range, and the case where an off-by-one or a
        // truncated read would still look plausible: 55 or 57 would pass any
        // "more than one" check.
        let entry = try numbering("7k00.bcif")
        let assembly = try #require(entry.assemblies.first)
        #expect(assembly.chainCount == 56)
    }

    @Test("A monomer declares one chain, and that is an answer rather than a gap")
    func monomersDeclareOneChain() throws {
        // Ubiquitin really is a monomer. Reading no assemblies at all would be
        // a different statement, and the viewer distinguishes "declares none"
        // from "could not look", so a monomer must land in the first case.
        for name in ["1ubq.bcif", "1hck.bcif", "6eqe.bcif"] {
            let entry = try numbering(name)
            let assembly = try #require(
                entry.assemblies.first, "\(name) declared no assembly at all")
            #expect(assembly.chainCount == 1, "\(name) should declare a monomer")
        }
    }

    @Test("Every fixture's assembly equals its asymmetric unit, which is the gap")
    func noFixtureExercisesConstruction() throws {
        // This test asserts a LIMITATION of the fixture set, so that adding a
        // genuine multimer fixture makes it fail and forces the construction
        // test to be written. A gap recorded only in prose is a gap that stays.
        for name in ["1ubq.bcif", "1hck.bcif", "2rh1.bcif", "6eqe.bcif", "1e8a.bcif", "7k00.bcif"] {
            let file = try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name)))
            let entry = EntryNumbering.from(file)
            let atoms = try AtomStore.from(file)
            let polymerChains = Set(
                (0..<atoms.count).filter { !atoms.isHeteroatom[$0] }.map { atoms.chainID[$0] })
            guard let declared = entry.assemblies.first?.chainCount else { continue }
            // Built first: `Comment` is ExpressibleByStringLiteral, so a
            // concatenation inline resolves as AttributedString instead.
            let detail =
                "\(name) declares \(declared) chains against \(polymerChains.count)"
                + " deposited: this fixture DOES exercise assembly construction, so the"
                + " viewer test for it can now be written"
            #expect(declared == polymerChains.count, "\(detail)")
        }
    }
}
