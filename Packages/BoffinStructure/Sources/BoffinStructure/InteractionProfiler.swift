//  InteractionProfiler.swift
//  BoffinStructure
//
//  A clean-room implementation of published non-covalent interaction criteria.
//
//  PLIP IS GPL v2 AND IS NEVER LINKED OR PORTED. Hard rule 4. What is
//  reimplemented here are the geometric criteria, which are standard structural
//  chemistry from the primary literature and not themselves anybody's property:
//  a distance cutoff between two carbons is not a copyrightable expression. No
//  PLIP source has been consulted or transcribed; the numbers come from the
//  criteria table in `Docs/BOFFIN_BUILD_PLAN.md` section 8.2, which cites them.
//
//  Protonation is the hard part, and the honest answer is to say what was
//  assumed
//  --------------------------------------------------------------------------
//  Most crystal structures have no hydrogens. Whether a histidine donates or
//  accepts, whether a carboxylate is charged, whether a cysteine is a thiolate:
//  all of it is inferred from residue and atom names at an assumed pH. An
//  interaction profile that guesses silently is worse than one that says what it
//  guessed, because the reader cannot tell which contacts survive a different
//  assumption. Every profile therefore carries its `Assumptions` with it.

import Foundation
import simd

/// The tunable geometry, in one struct so a criterion can be changed in one
/// place and seen in one place.
public struct InteractionCriteria: Sendable, Hashable {
    public var hydrophobicDistance: Double = 4.0
    public var hydrogenBondDistance: Double = 4.1
    /// Minimum donor-hydrogen-acceptor angle, in degrees.
    ///
    /// **Declared and not used.** Nothing reads this, and no hydrogen bond in
    /// this profiler is angle-filtered: the criterion is heavy-atom distance
    /// alone whether or not the structure carries hydrogens.
    ///
    /// Kept rather than deleted because the number is the right one and the
    /// gap is worth seeing. Applying it needs a decision that is not a
    /// programming one: hydrogens in most deposited structures are CALCULATED
    /// by refinement software rather than observed, so filtering on their
    /// geometry would be filtering on a model's assumptions and reporting the
    /// result as measurement.
    public var hydrogenBondAngle: Double = 100
    public var saltBridgeDistance: Double = 5.5
    public var metalDistance: Double = 3.0
    public var halogenDistance: Double = 4.0

    /// Smallest acceptable C-X...A angle for a halogen bond, in degrees.
    ///
    /// A halogen bond is strongly directional because the sigma-hole lies on
    /// the extension of the C-X bond, so the acceptor must be roughly along
    /// that axis. The published criterion is 165 degrees with a 30 degree
    /// tolerance, which is the 135 used here.
    ///
    /// Distance alone is not a halogen bond. Without this, a 4 A sphere around
    /// one chlorine caught three separate acceptors at once on 1XKK, which is
    /// geometrically impossible: one sigma-hole points one way.
    public var halogenAngle: Double = 135

    public init() {}
}

/// What had to be assumed to produce a profile.
public struct InteractionAssumptions: Sendable, Hashable {
    /// Whether the file contained explicit hydrogens.
    public let hasExplicitHydrogens: Bool
    public let pH: Double

    /// The sentence the UI must show. Not optional, and not a tooltip.
    public var statement: String {
        var lines = [
            "Protonation was inferred from residue and atom names at pH "
                + String(format: "%.1f", pH) + "."
        ]
        if hasExplicitHydrogens {
            // True again as of 2026-08-26, and it was not for months: the
            // sentence claimed the hydrogens were used for donor geometry while
            // nothing read them. It was corrected to say so, and then the
            // capability was built, so it says this instead.
            //
            // The caveat is the point. Most deposited hydrogens are PLACED by
            // refinement software at idealised geometry rather than observed,
            // so on those structures this filters contacts using a model's
            // assumptions. A reader is entitled to know which of the two they
            // are looking at, and the file does not say.
            lines.append(
                "The structure contains explicit hydrogens, and donor-hydrogen-acceptor "
                    + "angles below "
                    + String(format: "%.0f", InteractionCriteria().hydrogenBondAngle)
                    + " degrees were rejected. Note that hydrogens are usually placed by "
                    + "refinement software rather than observed, so on such a structure "
                    + "this filters on the refinement's assumptions.")
        } else {
            lines.append(
                "The structure has NO hydrogens, so donor and acceptor roles are "
                    + "assigned by atom type and hydrogen bond angles are not "
                    + "measured. Histidine is treated as neutral, aspartate and "
                    + "glutamate as charged, lysine and arginine as protonated.")
        }
        return lines.joined(separator: " ")
    }
}

/// One detected interaction.
public struct Interaction: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case hydrophobic
        case hydrogenBond
        case saltBridge
        case metalCoordination
        case halogenBond

        public var name: String {
            switch self {
            case .hydrophobic: "Hydrophobic contact"
            case .hydrogenBond: "Hydrogen bond"
            case .saltBridge: "Salt bridge"
            case .metalCoordination: "Metal coordination"
            case .halogenBond: "Halogen bond"
            }
        }
    }

    public let kind: Kind
    public let ligandAtom: Int
    /// The atom at the other end.
    ///
    /// Named `partnerAtom` and not `proteinAtom`, which is what it was called
    /// until a test noticed author numbers above 300 in a 298-residue kinase.
    /// Metal coordination is to the METAL, which is a heteroatom numbered in the
    /// ligand range, so a field called `proteinAtom` was accurate for four of
    /// the five kinds and quietly wrong for the fifth.
    public let partnerAtom: Int
    public let distance: Double

    public var id: String { "\(kind.rawValue)-\(ligandAtom)-\(partnerAtom)" }
}

/// A profile, and what it assumed.
public struct InteractionProfile: Sendable, Hashable {
    public let interactions: [Interaction]
    public let assumptions: InteractionAssumptions

    public func ofKind(_ kind: Interaction.Kind) -> [Interaction] {
        interactions.filter { $0.kind == kind }
    }

    /// Distinct partner residues contacted, as author numbers.
    ///
    /// Includes coordinated metals, which are part of a binding site even though
    /// they are not part of the protein.
    public func contactedResidues(in store: AtomStore) -> Set<Int> {
        Set(interactions.map { store.authorNumber[$0.partnerAtom] })
    }
}

public enum InteractionProfiler {

    /// Carbons and sulfurs with no polar neighbour: the apolar set.
    static let apolarElements: Set<String> = ["C", "S"]
    /// Nitrogen, oxygen and sulfur: donors and acceptors, before protonation.
    static let polarElements: Set<String> = ["N", "O", "S"]
    /// Halogens that can donate a halogen bond.
    ///
    /// **Fluorine is deliberately absent.** A halogen bond needs a positive
    /// sigma-hole on the halogen, opposite the C-X bond, and C-F has none:
    /// fluorine is too electronegative and too little polarisable to develop
    /// one, which is why organofluorine is not a halogen-bond donor while
    /// C-Cl, C-Br and C-I are, in that increasing order of strength.
    ///
    /// It was in this set, and the consequence was measurable rather than
    /// theoretical. Nothing in the fixture suite had ever exercised a
    /// halogenated ligand, so the rule had never run. On 1XKK, whose ligand
    /// lapatinib carries exactly one chlorine and one fluorine, the profiler
    /// reported eight halogen bonds and **five of them came from the single
    /// fluorine** -- more than the chlorine produced, because a smaller atom
    /// sits closer to more of its neighbours. Fluorine appears in roughly a
    /// fifth of marketed drugs, so on drug-like ligands the false positives
    /// would have outnumbered the real interactions.
    static let halogens: Set<String> = ["CL", "BR", "I"]

    /// Longest C-X covalent bond among the donors above, plus a margin.
    ///
    /// C-Cl is 1.74 A, C-Br 1.94 and C-I 2.14. 2.4 spans all three and stops
    /// short of the nearest non-bonded contact, the same trade the hydrogen
    /// attachment above makes at 1.3.
    static let carbonHalogenBondLength: Double = 2.4

    /// Residues carrying a formal positive charge at pH 7.4, with the atoms
    /// that carry it.
    static let cationicAtoms: [String: Set<String>] = [
        "ARG": ["NH1", "NH2", "NE"],
        "LYS": ["NZ"],
        "HIS": ["ND1", "NE2"],
    ]

    /// Residues carrying a formal negative charge at pH 7.4.
    static let anionicAtoms: [String: Set<String>] = [
        "ASP": ["OD1", "OD2"],
        "GLU": ["OE1", "OE2"],
    ]

    /// Profile the contacts between a ligand and the protein around it.
    ///
    /// - Parameters:
    ///   - store: the structure.
    ///   - ligand: atom indices of the ligand.
    ///   - criteria: the geometry, tunable in one place.
    ///   - pH: the pH the protonation assumptions are made at.
    /// - Returns: the interactions found, with the assumptions that produced
    ///   them.
    public static func profile(
        _ store: AtomStore, ligand: Set<Int>,
        criteria: InteractionCriteria = InteractionCriteria(),
        pH: Double = 7.4
    ) -> InteractionProfile {
        let hasHydrogens = (0..<store.count).contains {
            store.element[$0].uppercased() == "H"
        }
        let assumptions = InteractionAssumptions(
            hasExplicitHydrogens: hasHydrogens, pH: pH)

        guard !ligand.isEmpty else {
            return InteractionProfile(interactions: [], assumptions: assumptions)
        }

        // One conformation only, on both sides. A side chain refined in two
        // positions is one side chain, and counting both reports two contacts
        // where the crystallographer modelled one residue that cannot decide.
        // The inflation is silent and lands in a figure and a CSV.
        let conformation = Set(store.primaryConformationIndices())
        // The ligand comes in from a caller's selection, which was evaluated
        // over the whole store, so it needs the same narrowing: a ligand
        // modelled in two orientations would otherwise contact everything
        // twice.
        let ligand = ligand.intersection(conformation)
        guard !ligand.isEmpty else {
            return InteractionProfile(interactions: [], assumptions: assumptions)
        }

        let protein = Set(
            conformation.filter {
                !ligand.contains($0)
                    && SelectionEvaluator.polymerResidues.contains(
                        store.residueName[$0].uppercased())
                    && store.element[$0].uppercased() != "H"
            })
        let metals = Set(
            conformation.filter {
                SelectionEvaluator.metalResidues.contains(store.residueName[$0].uppercased())
            })

        // Hydrogens attached to each heavy atom, when the structure has any.
        //
        // Marc's decision, 2026-08-26: use explicit hydrogens for donor
        // geometry where a structure carries them. The trade is recorded on
        // `hydrogenBondAngle` and in the assumptions statement, because most
        // deposited hydrogens are placed by refinement software rather than
        // observed, so this filters on a model's assumptions for those.
        //
        // Attachment by distance, not by connectivity: BinaryCIF carries no
        // bond table for the polymer. 1.3 A comfortably spans the real bond
        // lengths (O-H 0.98, N-H 1.01, C-H 1.09) and stops well short of the
        // nearest non-bonded contact.
        var hydrogensByHeavyAtom: [Int: [Int]] = [:]
        if hasHydrogens {
            let hydrogens = conformation.filter { store.element[$0].uppercased() == "H" }
            for hydrogen in hydrogens {
                var closest: Int?
                var closestDistance = Double.greatestFiniteMagnitude
                for heavy in conformation where store.element[heavy].uppercased() != "H" {
                    guard let separation = store.distance(hydrogen, heavy) else { continue }
                    if separation < closestDistance, separation <= 1.3 {
                        closestDistance = separation
                        closest = heavy
                    }
                }
                // Attached to its NEAREST heavy atom only. A hydrogen between
                // two polar atoms is bonded to one of them and merely close to
                // the other, and assigning it to both would invent a donor.
                if let closest { hydrogensByHeavyAtom[closest, default: []].append(hydrogen) }
            }
        }

        // The carbon each halogen hangs off, by the same nearest-neighbour
        // reasoning as the hydrogens above. It is what makes the sigma-hole
        // direction computable: the hole lies on the far side of the halogen
        // from this carbon.
        var carbonForHalogen: [Int: Int] = [:]
        for atom in conformation
        where halogens.contains(store.element[atom].uppercased()) {
            var closest: Int?
            var closestDistance = Double.greatestFiniteMagnitude
            for carbon in conformation
            where store.element[carbon].uppercased() == "C" {
                guard let separation = store.distance(atom, carbon) else { continue }
                if separation < closestDistance,
                    separation <= carbonHalogenBondLength
                {
                    closestDistance = separation
                    closest = carbon
                }
            }
            if let closest { carbonForHalogen[atom] = closest }
        }

        /// The angle at `vertex` between `a` and `b`, in degrees.
        func angle(at vertex: Int, from a: Int, to b: Int) -> Double? {
            let vx = Double(store.x[vertex])
            let vy = Double(store.y[vertex])
            let vz = Double(store.z[vertex])
            let ax = Double(store.x[a]) - vx
            let ay = Double(store.y[a]) - vy
            let az = Double(store.z[a]) - vz
            let bx = Double(store.x[b]) - vx
            let by = Double(store.y[b]) - vy
            let bz = Double(store.z[b]) - vz
            let lengths =
                (ax * ax + ay * ay + az * az).squareRoot()
                * (bx * bx + by * by + bz * bz).squareRoot()
            guard lengths > 0 else { return nil }
            let cosine = (ax * bx + ay * by + az * bz) / lengths
            // Clamped for the same reason as the hydrogen-bond angle above.
            return Foundation.acos(min(max(cosine, -1), 1)) * 180 / Double.pi
        }

        /// Whether a donor-hydrogen-acceptor angle clears the criterion.
        ///
        /// Measured AT the hydrogen, between the vector back to its donor and
        /// the vector on to the acceptor. A linear hydrogen bond is near 180
        /// degrees, so the cutoff is a floor.
        func donates(_ donor: Int, to acceptor: Int) -> Bool {
            guard let attached = hydrogensByHeavyAtom[donor] else { return false }
            return attached.contains { hydrogen in
                let hx = Double(store.x[hydrogen])
                let hy = Double(store.y[hydrogen])
                let hz = Double(store.z[hydrogen])
                let dx = Double(store.x[donor]) - hx
                let dy = Double(store.y[donor]) - hy
                let dz = Double(store.z[donor]) - hz
                let ax = Double(store.x[acceptor]) - hx
                let ay = Double(store.y[acceptor]) - hy
                let az = Double(store.z[acceptor]) - hz

                let donorLength = (dx * dx + dy * dy + dz * dz).squareRoot()
                let acceptorLength = (ax * ax + ay * ay + az * az).squareRoot()
                let lengths = donorLength * acceptorLength
                guard lengths > 0 else { return false }
                let cosine = (dx * ax + dy * ay + dz * az) / lengths
                // Clamped before acos: three nearly collinear atoms put the
                // cosine a hair outside [-1, 1] and acos(1.0000000001) is NaN,
                // which would compare false and silently drop a perfect bond.
                let angle = Foundation.acos(min(max(cosine, -1), 1)) * 180 / Double.pi
                return angle >= criteria.hydrogenBondAngle
            }
        }

        var found: [Interaction] = []
        let widest = max(
            criteria.hydrophobicDistance,
            max(criteria.hydrogenBondDistance, criteria.saltBridgeDistance))

        for ligandAtom in ligand {
            let ligandElement = store.element[ligandAtom].uppercased()
            let neighbours = SelectionEvaluator.withinIndices(
                distance: widest, candidates: protein, targets: [ligandAtom], store: store)

            for partnerAtom in neighbours {
                guard let separation = store.distance(ligandAtom, partnerAtom) else {
                    continue
                }
                let proteinElement = store.element[partnerAtom].uppercased()
                let proteinResidue = store.residueName[partnerAtom].uppercased()
                let proteinName = store.atomName[partnerAtom].uppercased()

                // Hydrophobic: carbon to carbon, close.
                if separation <= criteria.hydrophobicDistance,
                    ligandElement == "C", proteinElement == "C"
                {
                    found.append(
                        Interaction(
                            kind: .hydrophobic, ligandAtom: ligandAtom,
                            partnerAtom: partnerAtom, distance: separation))
                }

                // Hydrogen bond.
                //
                // Heavy-atom distance alone when the structure has no
                // hydrogens: the angle criterion is not applied silently to a
                // structure that cannot support it, and the assumptions say so.
                //
                // Where hydrogens ARE present, one of the two atoms must
                // actually donate at an acceptable angle. That also rejects
                // acceptor-acceptor pairs, which distance alone accepts: two
                // carbonyl oxygens 3 A apart are close, and neither can donate
                // to the other.
                let angleSatisfied =
                    !hasHydrogens
                    || donates(ligandAtom, to: partnerAtom)
                    || donates(partnerAtom, to: ligandAtom)
                if separation <= criteria.hydrogenBondDistance,
                    angleSatisfied,
                    polarElements.contains(ligandElement),
                    polarElements.contains(proteinElement)
                {
                    found.append(
                        Interaction(
                            kind: .hydrogenBond, ligandAtom: ligandAtom,
                            partnerAtom: partnerAtom, distance: separation))
                }

                // Salt bridge: opposite formal charges at the assumed pH.
                if separation <= criteria.saltBridgeDistance {
                    let proteinCationic =
                        cationicAtoms[proteinResidue]?.contains(proteinName) ?? false
                    let proteinAnionic =
                        anionicAtoms[proteinResidue]?.contains(proteinName) ?? false
                    let ligandAnionic = ["O", "S"].contains(ligandElement)
                    let ligandCationic = ligandElement == "N"
                    if (proteinCationic && ligandAnionic)
                        || (proteinAnionic && ligandCationic)
                    {
                        found.append(
                            Interaction(
                                kind: .saltBridge, ligandAtom: ligandAtom,
                                partnerAtom: partnerAtom, distance: separation))
                    }
                }

                // Halogen bond: distance AND the donor angle. The comment
                // here used to say the angle criteria needed connectivity the
                // file does not carry, so only distance was tested. Half of
                // that was true. The acceptor-side angle does need the
                // acceptor's own covalent neighbour and is still not tested,
                // but the donor side only needs the carbon the halogen hangs
                // off, and that is recoverable by distance exactly as the
                // hydrogens above are. It is now tested, and it is what
                // separates a halogen bond from a close contact.
                if separation <= criteria.halogenDistance,
                    halogens.contains(ligandElement),
                    ["N", "O", "S"].contains(proteinElement),
                    // Directional, not merely close. A halogen with no carbon
                    // found is not reported at all: without the C-X axis there
                    // is no sigma-hole direction to test, and reporting it
                    // anyway is the distance-only rule wearing an angle's name.
                    let carbon = carbonForHalogen[ligandAtom],
                    let sigmaHole = angle(at: ligandAtom, from: carbon, to: partnerAtom),
                    sigmaHole >= criteria.halogenAngle
                {
                    found.append(
                        Interaction(
                            kind: .halogenBond, ligandAtom: ligandAtom,
                            partnerAtom: partnerAtom, distance: separation))
                }
            }

            // Metal coordination is to the metal, not to the protein, so it is
            // a separate sweep.
            if polarElements.contains(ligandElement) {
                for metal in metals {
                    guard let separation = store.distance(ligandAtom, metal),
                        separation <= criteria.metalDistance
                    else { continue }
                    found.append(
                        Interaction(
                            kind: .metalCoordination, ligandAtom: ligandAtom,
                            partnerAtom: metal, distance: separation))
                }
            }
        }

        return InteractionProfile(
            interactions: found.sorted { $0.distance < $1.distance },
            assumptions: assumptions)
    }
}
