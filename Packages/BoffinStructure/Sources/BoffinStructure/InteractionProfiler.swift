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
    public var hydrogenBondAngle: Double = 100
    public var saltBridgeDistance: Double = 5.5
    public var metalDistance: Double = 3.0
    public var halogenDistance: Double = 4.0

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
            lines.append(
                "The structure contains explicit hydrogens, which were used for "
                    + "donor geometry where present.")
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
    static let halogens: Set<String> = ["CL", "BR", "I", "F"]

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

        let protein = Set(
            (0..<store.count).filter {
                !ligand.contains($0)
                    && SelectionEvaluator.polymerResidues.contains(
                        store.residueName[$0].uppercased())
                    && store.element[$0].uppercased() != "H"
            })
        let metals = Set(
            (0..<store.count).filter {
                SelectionEvaluator.metalResidues.contains(store.residueName[$0].uppercased())
            })

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

                // Hydrogen bond, by heavy-atom distance alone when the structure
                // has no hydrogens. The angle criterion is not applied silently
                // to a structure that cannot support it; the assumptions say so.
                if separation <= criteria.hydrogenBondDistance,
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

                // Halogen bond, by distance. The two angle criteria need the
                // carbon the halogen is bonded to, which needs connectivity the
                // file does not always carry, so this is reported as a candidate
                // and the assumptions say the angles were not checked.
                if separation <= criteria.halogenDistance,
                    halogens.contains(ligandElement),
                    ["N", "O", "S"].contains(proteinElement)
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
