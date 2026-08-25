//  Measurement.swift
//  BoffinStructure
//
//  Distances, angles and dihedrals between selected atoms.
//
//  Small enough to be obvious and worth writing carefully anyway: a dihedral is
//  the one where sign conventions differ between textbooks, and a viewer that
//  reports the wrong sign for a torsion is reporting the wrong conformation.
//
//  The IUPAC convention is used throughout: looking from atom 2 to atom 3, the
//  dihedral is the angle from the projection of atom 1 to that of atom 4,
//  positive clockwise, in the range -180 to 180.

import Foundation
import simd

/// A geometric measurement between atoms of one structure.
public enum StructureMeasurement: Sendable, Hashable, Identifiable {
    case distance(from: Int, to: Int, angstroms: Double)
    case angle(a: Int, b: Int, c: Int, degrees: Double)
    case dihedral(a: Int, b: Int, c: Int, d: Int, degrees: Double)

    public var id: String {
        switch self {
        case .distance(let from, let to, _): "d-\(from)-\(to)"
        case .angle(let a, let b, let c, _): "a-\(a)-\(b)-\(c)"
        case .dihedral(let a, let b, let c, let d, _): "t-\(a)-\(b)-\(c)-\(d)"
        }
    }

    public var value: Double {
        switch self {
        case .distance(_, _, let value): value
        case .angle(_, _, _, let value): value
        case .dihedral(_, _, _, _, let value): value
        }
    }

    /// How the measurement reads on a label, with its unit.
    public var label: String {
        switch self {
        case .distance(_, _, let value): String(format: "%.2f A", value)
        case .angle(_, _, _, let value):
            String(format: "%.1f degrees", value)
        case .dihedral(_, _, _, _, let value):
            String(format: "%.1f degrees", value)
        }
    }
}

extension AtomStore {

    func position(_ index: Int) -> SIMD3<Double> {
        SIMD3(Double(x[index]), Double(y[index]), Double(z[index]))
    }

    /// Distance in angstroms.
    public func distance(_ a: Int, _ b: Int) -> Double? {
        guard indicesAreValid(a, b) else { return nil }
        return simd_distance(position(a), position(b))
    }

    /// Angle at `b`, in degrees, between 0 and 180.
    public func angle(_ a: Int, _ b: Int, _ c: Int) -> Double? {
        guard indicesAreValid(a, b, c) else { return nil }
        let first = position(a) - position(b)
        let second = position(c) - position(b)
        let lengths = simd_length(first) * simd_length(second)
        guard lengths > 0 else { return nil }
        // Clamped before acos: floating point can put the cosine a hair outside
        // [-1, 1] for three nearly collinear atoms, and acos of 1.0000000001 is
        // NaN, which then propagates into a label reading "nan degrees".
        let cosine = min(max(simd_dot(first, second) / lengths, -1), 1)
        return acos(cosine) * 180 / .pi
    }

    /// Dihedral about the `b`-`c` bond, in degrees, from -180 to 180.
    ///
    /// IUPAC sign convention: looking from `b` to `c`, positive is clockwise.
    /// The sign is the whole point of a torsion, so it is computed with the
    /// atan2 form rather than from the cosine alone, which loses it.
    public func dihedral(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double? {
        guard indicesAreValid(a, b, c, d) else { return nil }
        let first = position(b) - position(a)
        let second = position(c) - position(b)
        let third = position(d) - position(c)

        let normalOne = simd_cross(first, second)
        let normalTwo = simd_cross(second, third)
        let axis = simd_cross(normalOne, normalTwo)

        let length = simd_length(second)
        guard length > 0 else { return nil }
        let y = simd_dot(axis, second / length)
        let x = simd_dot(normalOne, normalTwo)
        guard x != 0 || y != 0 else { return nil }
        return atan2(y, x) * 180 / .pi
    }

    private func indicesAreValid(_ values: Int...) -> Bool {
        values.allSatisfy { $0 >= 0 && $0 < count }
    }

    /// A human-readable name for an atom: `A/ASP145/CA`.
    ///
    /// Author numbering, because that is what a paper quotes and what the label
    /// on a figure has to match.
    public func describe(_ index: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        return "\(chainID[index])/\(residueName[index])\(authorNumber[index])/\(atomName[index])"
    }
}
