//  SecondaryStructure.swift
//  BoffinStructure
//
//  Eight-state secondary structure assigned from coordinates: a clean-room
//  implementation of Kabsch and Sander's published method.
//
//  Why this is here at all
//  -----------------------
//  The Q8 head is trained on NetSurfP's distribution of CB513, whose terms are
//  unstated, and that has blocked release since Phase 3. The labels are DSSP
//  assignments over PDB structures, and the PDB is CC0. So the way to unblock
//  the head is to compute the labels rather than redistribute somebody else's,
//  which is the same move that unblocked the transmembrane head and the residue
//  numbering.
//
//  Kabsch and Sander, *Dictionary of protein secondary structure*, Biopolymers
//  22:2577 (1983). The algorithm is published and the constants below are from
//  the paper. No DSSP source has been read: the implementation is from the
//  description, which is the same footing as the interaction profiler.
//
//  What it needs and what it does with what it has not got
//  --------------------------------------------------------
//  Backbone N, CA, C and O. A residue missing any of them cannot participate in
//  a hydrogen bond and is assigned `.unknown` rather than `.coil`: coil is a
//  statement about the structure and unknown is a statement about the data, and
//  a chain break silently labelled coil is a chain break that trains a model.

import Foundation
import simd

/// Eight-state secondary structure, DSSP's alphabet.
public enum DSSPState: Character, Sendable, CaseIterable {
    case alphaHelix = "H"
    case threeTenHelix = "G"
    case piHelix = "I"
    case betaStrand = "E"
    case betaBridge = "B"
    case turn = "T"
    case bend = "S"
    case coil = "C"
    /// Not assignable: the backbone is incomplete here.
    case unknown = "-"

    /// The standard three-state collapse.
    public var threeState: Character {
        switch self {
        case .alphaHelix, .threeTenHelix, .piHelix: "H"
        case .betaStrand, .betaBridge: "E"
        case .turn, .bend, .coil: "C"
        case .unknown: "-"
        }
    }
}

public enum SecondaryStructureAssigner {

    /// Kabsch and Sander's hydrogen bond energy cutoff, in kcal/mol.
    public static let energyCutoff = -0.5

    /// The paper's electrostatic constant: 0.084 * 332.
    static let couplingConstant = 27.888

    /// One residue's backbone, as the assigner needs it.
    struct Backbone {
        let nitrogen: SIMD3<Double>?
        let alpha: SIMD3<Double>?
        let carbon: SIMD3<Double>?
        let oxygen: SIMD3<Double>?
        /// Author number, for chain-break detection.
        let number: Int
        let chain: String
        let residueName: String

        var isComplete: Bool {
            nitrogen != nil && alpha != nil && carbon != nil && oxygen != nil
        }
    }

    /// Assign secondary structure for one chain.
    ///
    /// - Parameters:
    ///   - store: the structure.
    ///   - chain: the author chain identifier.
    /// - Returns: one state per residue of that chain, in author-number order.
    public static func assign(_ store: AtomStore, chain: String) -> [DSSPState] {
        let residues = backbones(store, chain: chain)
        guard residues.count > 1 else {
            return [DSSPState](repeating: .unknown, count: residues.count)
        }

        // Hydrogen bonds: `bonded[i][j]` means residue i's N-H donates to
        // residue j's C=O.
        var bonded = [[Bool]](
            repeating: [Bool](repeating: false, count: residues.count),
            count: residues.count)
        for donor in residues.indices {
            for acceptor in residues.indices {
                if hasHydrogenBond(residues, donor: donor, acceptor: acceptor) {
                    bonded[donor][acceptor] = true
                }
            }
        }

        var states = [DSSPState](repeating: .coil, count: residues.count)
        for index in residues.indices where !residues[index].isComplete {
            states[index] = .unknown
        }

        // n-turns: residue i has an n-turn if i+n donates to i.
        func turn(_ index: Int, _ n: Int) -> Bool {
            let other = index + n
            guard other < residues.count else { return false }
            return bonded[other][index]
        }

        // Helices, longest first: a residue in both a 4-helix and a 3-helix is
        // alpha, which is the paper's precedence and not a preference.
        for (n, state) in [(4, DSSPState.alphaHelix), (3, .threeTenHelix), (5, .piHelix)] {
            for index in residues.indices {
                guard turn(index, n), index + 1 < residues.count,
                    turn(index - 1 >= 0 ? index - 1 : index, n)
                else { continue }
                for offset in 1..<n where index + offset < residues.count {
                    if states[index + offset] == .coil { states[index + offset] = state }
                }
            }
        }

        // Bridges. Two residues form a bridge if their neighbours hydrogen bond
        // in one of the two published patterns.
        // `stride` rather than a range, because `(i + 3)..<(count - 1)` is an
        // INVALID range whenever the chain is short: Swift traps with "Range
        // requires lowerBound <= upperBound" rather than yielding nothing, and a
        // four-residue peptide is enough to do it.
        var isBridge = [Bool](repeating: false, count: residues.count)
        for i in stride(from: 1, to: max(residues.count - 1, 1), by: 1) {
            for j in stride(from: i + 3, to: max(residues.count - 1, i + 3), by: 1) {
                let parallel =
                    (bonded[i][j] && bonded[j][i + 1])
                    || (bonded[j - 1][i] && bonded[i][j + 1])
                let antiparallel =
                    (bonded[i][j] && bonded[j][i])
                    || (bonded[i - 1][j + 1] && bonded[j - 1][i + 1])
                if parallel || antiparallel {
                    isBridge[i] = true
                    isBridge[j] = true
                }
            }
        }
        for index in residues.indices where isBridge[index] && states[index] == .coil {
            states[index] = .betaStrand
        }
        // An isolated bridge is B, not E: a single residue does not make a
        // sheet, and calling it one inflates strand content in exactly the
        // structures with the least of it.
        for index in residues.indices where states[index] == .betaStrand {
            let before = index > 0 && states[index - 1] == .betaStrand
            let after = index + 1 < residues.count && states[index + 1] == .betaStrand
            if !before && !after { states[index] = .betaBridge }
        }

        // Turns: any residue inside an n-turn that is not already helix or
        // strand.
        for index in residues.indices {
            guard states[index] == .coil else { continue }
            for n in 3...5 {
                for start in stride(from: max(0, index - n + 1), through: index, by: 1)
                where turn(start, n) {
                    if start < index, index < start + n {
                        states[index] = .turn
                    }
                }
            }
        }

        // Bends: a sharp kink in the chain, defined by the angle between the
        // vectors two residues either side.
        for index in stride(from: 2, to: max(residues.count - 2, 2), by: 1)
        where states[index] == .coil {
            guard let before = residues[index - 2].alpha,
                let here = residues[index].alpha,
                let after = residues[index + 2].alpha
            else { continue }
            let incoming = simd_normalize(here - before)
            let outgoing = simd_normalize(after - here)
            let angle = acos(min(max(simd_dot(incoming, outgoing), -1), 1)) * 180 / .pi
            if angle > 70 { states[index] = .bend }
        }

        return states
    }

    /// Whether residue `donor`'s N-H donates to residue `acceptor`'s C=O.
    static func hasHydrogenBond(
        _ residues: [Backbone], donor: Int, acceptor: Int
    ) -> Bool {
        guard donor >= 0, acceptor >= 0, donor < residues.count, acceptor < residues.count
        else { return false }
        // A residue cannot bond to itself or its immediate neighbour: the
        // geometry is meaningless and the energy is spuriously large.
        guard abs(donor - acceptor) >= 2 else { return false }
        guard donor > 0 else { return false }

        let donorResidue = residues[donor]
        let previous = residues[donor - 1]
        let acceptorResidue = residues[acceptor]
        guard donorResidue.chain == acceptorResidue.chain else { return false }
        guard let nitrogen = donorResidue.nitrogen,
            let carbon = acceptorResidue.carbon,
            let oxygen = acceptorResidue.oxygen,
            let previousCarbon = previous.carbon,
            let previousOxygen = previous.oxygen
        else { return false }

        // Proline has no amide hydrogen and cannot donate. Missing this makes
        // helices one residue too long wherever a proline caps one, which is
        // most of them.
        if donorResidue.residueName == "PRO" { return false }

        // The hydrogen is placed on the nitrogen along the previous residue's
        // C=O direction, which is the paper's construction and the reason the
        // previous residue is needed at all.
        let direction = previousCarbon - previousOxygen
        let length = simd_length(direction)
        guard length > 0 else { return false }
        let hydrogen = nitrogen + direction / length

        func inverse(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let separation = simd_distance(a, b)
            return separation > 0.1 ? 1 / separation : 10
        }

        let energy =
            couplingConstant
            * (inverse(oxygen, nitrogen) + inverse(carbon, hydrogen)
                - inverse(oxygen, hydrogen) - inverse(carbon, nitrogen))
        return energy < energyCutoff
    }

    static func backbones(_ store: AtomStore, chain: String) -> [Backbone] {
        var byResidue:
            [Int: (
                n: SIMD3<Double>?, a: SIMD3<Double>?, c: SIMD3<Double>?, o: SIMD3<Double>?,
                name: String
            )] = [:]
        var order: [Int] = []
        for index in 0..<store.count {
            guard store.chainID[index] == chain, !store.isHeteroatom[index] else { continue }
            let number = store.authorNumber[index]
            if byResidue[number] == nil {
                byResidue[number] = (nil, nil, nil, nil, store.residueName[index])
                order.append(number)
            }
            let point = SIMD3(
                Double(store.x[index]), Double(store.y[index]), Double(store.z[index]))
            switch store.atomName[index].uppercased() {
            case "N": byResidue[number]?.n = point
            case "CA": byResidue[number]?.a = point
            case "C": byResidue[number]?.c = point
            case "O": byResidue[number]?.o = point
            default: break
            }
        }
        return order.sorted().compactMap { number in
            guard let entry = byResidue[number] else { return nil }
            return Backbone(
                nitrogen: entry.n, alpha: entry.a, carbon: entry.c, oxygen: entry.o,
                number: number, chain: chain, residueName: entry.name)
        }
    }
}
