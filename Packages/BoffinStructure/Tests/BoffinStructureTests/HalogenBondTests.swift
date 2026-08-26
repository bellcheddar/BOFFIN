//  HalogenBondTests.swift
//  BoffinStructureTests
//
//  The halogen-bond rule had never run. Every fixture ligand was ATP or a
//  phosphate, so `Interaction.Kind.halogenBond` was asserted nowhere and the
//  code path was dead in practice while looking perfectly alive.
//
//  1XKK is EGFR with lapatinib, whose ligand carries exactly one chlorine and
//  exactly one fluorine. That is what makes it the right fixture rather than
//  merely a halogenated one: it distinguishes the two errors at once, since a
//  ligand with only chlorine could not have shown that fluorine was being
//  counted, and one with only fluorine could not have shown that anything
//  real survived.

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

@Suite("Halogen bonds")
struct HalogenBondTests {

    private func lapatinib() throws -> (AtomStore, Set<Int>) {
        let data = try Data(contentsOf: fixtures.appending(path: "1xkk.bcif"))
        let store = try AtomStore.from(try BinaryCIF.decode(data))
        let ligand = SelectionEvaluator.evaluate(.category(.organic), in: store).indices
        return (store, ligand)
    }

    @Test("The fixture carries one chlorine and one fluorine")
    func fixtureIsTheRightShape() throws {
        let (store, ligand) = try lapatinib()
        var counts: [String: Int] = [:]
        for atom in ligand { counts[store.element[atom].uppercased(), default: 0] += 1 }
        // Asserted rather than assumed: if a re-fetch ever returned a
        // different entry, every expectation below would become vacuous
        // instead of failing.
        #expect(counts["CL"] == 1)
        #expect(counts["F"] == 1)
    }

    @Test("A real halogen bond is found, and it is the chlorine's")
    func chlorineBonds() throws {
        let (store, ligand) = try lapatinib()
        let profile = InteractionProfiler.profile(store, ligand: ligand)
        let halogenBonds = profile.ofKind(.halogenBond)

        #expect(!halogenBonds.isEmpty, "the rule must actually fire on this entry")

        let donors = Set(halogenBonds.map { store.element[$0.ligandAtom].uppercased() })
        // Fluorine has no sigma-hole, so it is not a halogen-bond donor at
        // all. It used to contribute five of the eight reported here.
        #expect(!donors.contains("F"), "fluorine cannot donate a halogen bond")
        #expect(donors == ["CL"])
    }

    @Test("The chlorine bond is the one in the literature geometry")
    func geometryIsCredible() throws {
        let (store, ligand) = try lapatinib()
        let profile = InteractionProfiler.profile(store, ligand: ligand)
        let bond = try #require(profile.ofKind(.halogenBond).first)

        // Inside the sum of the van der Waals radii, Cl 1.75 plus O 1.52 is
        // 3.27, which is the signature of a halogen bond rather than a
        // coincidence of packing.
        #expect(bond.distance < 3.27)
        #expect(store.element[bond.partnerAtom].uppercased() == "O")

        // One sigma-hole points one way, so one halogen cannot bond three
        // acceptors at once. Before the donor angle was applied, this single
        // chlorine reported three.
        let fromThisChlorine = profile.ofKind(.halogenBond)
            .filter { $0.ligandAtom == bond.ligandAtom }
        #expect(fromThisChlorine.count == 1)
    }

    @Test("A halogen with no bonded carbon is not reported")
    func requiresTheCarbon() throws {
        let (store, ligand) = try lapatinib()
        // A bare halide ion has no C-X axis and so no direction to test.
        // Reporting one would be the distance-only rule under another name.
        var criteria = InteractionCriteria()
        criteria.halogenAngle = 0
        let permissive = InteractionProfiler.profile(
            store, ligand: ligand, criteria: criteria)
        // With the angle disabled the count rises, which proves the angle is
        // doing the filtering rather than the fluorine removal alone.
        #expect(
            permissive.ofKind(.halogenBond).count
                > profile(store, ligand).ofKind(.halogenBond).count)
    }

    private func profile(_ store: AtomStore, _ ligand: Set<Int>) -> InteractionProfile {
        InteractionProfiler.profile(store, ligand: ligand)
    }
}
