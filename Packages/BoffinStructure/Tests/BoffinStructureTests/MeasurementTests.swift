//  MeasurementTests.swift
//  BoffinStructureTests
//
//  Geometry is checked against constructed cases with answers known by hand, and
//  then against a real structure where the answer is in the literature. The
//  dihedral sign is the part worth the trouble: a viewer that reports the wrong
//  sign for a torsion is reporting the wrong conformation, and both signs look
//  equally plausible on screen.

import Foundation
import Testing

@testable import BoffinStructure

private func makeStore(_ points: [(Float, Float, Float)]) -> AtomStore {
    var store = AtomStore()
    for (index, point) in points.enumerated() {
        store.append(
            x: point.0, y: point.1, z: point.2, element: "C", atomName: "C\(index)",
            residueName: "ALA", authorNumber: 1, chainID: "A", bFactor: 0,
            occupancy: 1, altLoc: "", isHeteroatom: false, model: 1)
    }
    return store
}

@Suite("Geometry")
struct MeasurementTests {

    @Test("Distance is what a ruler would say")
    func distance() {
        let store = makeStore([(0, 0, 0), (3, 4, 0)])
        #expect(store.distance(0, 1) == 5)
        #expect(store.distance(0, 0) == 0)
        #expect(store.distance(0, 5) == nil)
        #expect(store.distance(-1, 0) == nil)
    }

    @Test("Angle is measured at the middle atom")
    func angle() throws {
        let right = makeStore([(1, 0, 0), (0, 0, 0), (0, 1, 0)])
        let value = try #require(right.angle(0, 1, 2))
        #expect(abs(value - 90) < 1e-6)

        let straight = makeStore([(1, 0, 0), (0, 0, 0), (-1, 0, 0)])
        #expect(abs(try #require(straight.angle(0, 1, 2)) - 180) < 1e-6)

        // Three collinear atoms in the same direction: zero, not NaN. Floating
        // point can put the cosine a hair outside [-1, 1] here, and acos of
        // 1.0000000001 is NaN, which reaches the label as "nan degrees".
        let collinear = makeStore([(1, 0, 0), (0, 0, 0), (2, 0, 0)])
        let degenerate = try #require(collinear.angle(0, 1, 2))
        #expect(degenerate.isFinite)
        #expect(abs(degenerate) < 1e-4)
    }

    /// IUPAC: looking from atom 2 to atom 3, positive is clockwise. Both signs
    /// look plausible on screen, so they are pinned on constructed geometry
    /// where the answer is not a matter of opinion.
    @Test("Dihedral carries the sign, which is the whole point of a torsion")
    func dihedral() throws {
        // Planar cis: all four atoms in a plane, atoms 1 and 4 on the same side.
        let cis = makeStore([(1, 1, 0), (0, 0, 0), (1, 0, 0), (2, 1, 0)])
        #expect(abs(try #require(cis.dihedral(0, 1, 2, 3))) < 1e-4)

        // Planar trans: atoms 1 and 4 on OPPOSITE sides of the b-c axis.
        //
        // The first attempt used (-1, 1, 0) and (2, 1, 0), which puts both
        // perpendicular components on +y and is therefore another cis case. The
        // dihedral does not care where along the axis an atom sits, only which
        // way it points away from it.
        let trans = makeStore([(1, 1, 0), (0, 0, 0), (1, 0, 0), (2, -1, 0)])
        #expect(abs(abs(try #require(trans.dihedral(0, 1, 2, 3))) - 180) < 1e-4)

        // Ninety degrees, and the mirror image must give the opposite sign.
        let positive = makeStore([(0, 1, 0), (0, 0, 0), (1, 0, 0), (1, 0, 1)])
        let mirror = makeStore([(0, 1, 0), (0, 0, 0), (1, 0, 0), (1, 0, -1)])
        let one = try #require(positive.dihedral(0, 1, 2, 3))
        let other = try #require(mirror.dihedral(0, 1, 2, 3))
        #expect(abs(abs(one) - 90) < 1e-4)
        #expect(abs(one + other) < 1e-4, "\(one) and \(other) are not mirror images")
    }

    @Test("Degenerate input is nil rather than a number")
    func degenerate() {
        let coincident = makeStore([(0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0)])
        #expect(coincident.angle(0, 1, 2) == nil)
        #expect(coincident.dihedral(0, 1, 2, 3) == nil)
        #expect(coincident.distance(0, 9) == nil)
    }

    /// A real structure, checked against chemistry rather than against the code.
    @Test("Ubiquitin's bond lengths and backbone geometry are physical")
    func realStructure() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/structures/1ubq.bcif")
        let store = try AtomStore.from(try BinaryCIF.decode(Data(contentsOf: url)))

        func atom(_ residue: Int, _ name: String) throws -> Int {
            try #require(
                (0..<store.count).first {
                    store.authorNumber[$0] == residue && store.atomName[$0] == name
                        && !store.isHeteroatom[$0]
                }, "no \(name) in residue \(residue)")
        }

        // A peptide bond is about 1.33 A: C of one residue to N of the next.
        let carbonyl = try atom(1, "C")
        let nextNitrogen = try atom(2, "N")
        let bond = try #require(store.distance(carbonyl, nextNitrogen))
        #expect(abs(bond - 1.33) < 0.10, "peptide bond measured \(bond) A")

        // N-CA-C, the backbone angle, is about 111 degrees.
        let tau = try #require(
            store.angle(try atom(2, "N"), try atom(2, "CA"), try atom(2, "C")))
        #expect(abs(tau - 111) < 8, "tau measured \(tau) degrees")

        // Omega, the peptide torsion, is trans in essentially every residue:
        // close to 180 either way.
        let omega = try #require(
            store.dihedral(
                try atom(1, "CA"), try atom(1, "C"), try atom(2, "N"), try atom(2, "CA")))
        #expect(abs(abs(omega) - 180) < 20, "omega measured \(omega) degrees")

        #expect(store.describe(carbonyl) == "A/MET1/C")
    }
}
