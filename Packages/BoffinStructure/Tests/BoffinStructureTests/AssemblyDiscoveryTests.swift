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
//  Building the assembly was therefore a no-op on all seven, which is the real
//  reason an earlier UI test asserting construction was deleted rather than
//  tuned: there was nothing meaningful for it to assert.
//
//  **1FHA closes that gap**, added 2026-08-26. Human ferritin heavy chain
//  declares a 24-mer and deposits a single chain, so building its assembly
//  multiplies the structure twenty-four-fold. A viewer that ignores the
//  assembly shows one twenty-fourth of the protein and looks entirely
//  reasonable doing it.

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

    @Test("1FHA declares a 24-mer and deposits one chain")
    func ferritinExpands() throws {
        // The fixture added on 2026-08-26 to make assembly CONSTRUCTION
        // testable at all. Human ferritin heavy chain: the deposited
        // coordinates are one subunit and the molecule is a 24-subunit shell,
        // so a viewer that ignores the assembly shows 1/24th of the protein
        // and looks perfectly reasonable doing it.
        let entry = try numbering("1fha.bcif")
        let assembly = try #require(entry.assemblies.first)
        #expect(assembly.chainCount == 24, "ferritin is a 24-mer")

        let atoms = try AtomStore.from(
            try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: "1fha.bcif"))))
        let deposited = Set(
            (0..<atoms.count).filter { !atoms.isHeteroatom[$0] }.map { atoms.chainID[$0] })
        #expect(deposited.count == 1, "the asymmetric unit holds a single chain")
        #expect(
            assembly.chainCount ?? 0 > deposited.count,
            "this is the whole point of the fixture: the assembly must exceed the deposit")
    }

    @Test("The other fixtures' assemblies still equal their asymmetric units")
    func otherFixturesDoNotExerciseConstruction() throws {
        // Kept as a record of WHY 1FHA had to be added, and still live: if one
        // of these ever gains an assembly differing from its deposit, that is
        // worth knowing rather than discovering during a debugging session.
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
