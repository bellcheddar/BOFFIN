//  Disulfides.swift
//  BoffinStructure
//
//  Finding disulfide bonds in a structure, by geometry.
//
//  Why geometry rather than the deposited `_struct_conn` annotation: the
//  annotation is the depositor's, it is absent from a predicted model
//  altogether, and BOFFIN already reads geometry for interactions and secondary
//  structure. Measuring it here means one answer produced one way, and it works
//  on an AlphaFold model where there is nothing to read.
//
//  This matters to the Boundary tab specifically. A construct boundary that
//  falls between two cysteines that pair separates a covalent bond, and the
//  protein that comes out of the cell will not fold. Nothing in a SEQUENCE says
//  which cysteines pair, which is why this is the one construct constraint that
//  had to wait for the structure viewer.
//
//  Three things that look like details and are not
//  ----------------------------------------------
//
//  **Sulfur forms one bond.** A naive "every SG pair under the cutoff" search
//  will happily pair one sulfur with two partners, which is not a close call,
//  it is chemically impossible. Real structures produce it anyway: a cysteine
//  modelled in two conformations, or a crowded active site, puts three SG atoms
//  inside 2.5 A of each other. Pairs are therefore assigned by a greedy
//  shortest-first matching in which each sulfur is used once.
//
//  **Alternate locations are two models of one atom, not two atoms.** A
//  cysteine modelled half bonded and half free has two SG atoms at the same
//  residue, roughly 1 A apart. Counting both invents a disulfide from a residue
//  to itself. Only the highest-occupancy altloc of each residue is considered.
//
//  **An NMR ensemble is twenty copies of the protein.** Searching all models at
//  once pairs a sulfur in model 1 with its own image in model 7, at a distance
//  of nothing at all. One model is searched.

import Foundation

/// A disulfide bond between two cysteine residues.
public struct Disulfide: Sendable, Hashable {
    public let firstChain: String
    public let firstNumber: Int
    public let secondChain: String
    public let secondNumber: Int
    /// SG to SG distance, in angstroms.
    public let distance: Float

    /// Whether both cysteines are in the same chain.
    ///
    /// Only an intra-chain pair constrains a construct's boundaries. An
    /// inter-chain disulfide is a real bond and a different problem: it says
    /// something about the assembly rather than about where this chain may be
    /// cut.
    public var isIntrachain: Bool { firstChain == secondChain }

    /// The span a boundary must not fall inside, for an intra-chain pair.
    ///
    /// Author numbering, inclusive, low to high.
    public var span: ClosedRange<Int>? {
        guard isIntrachain else { return nil }
        return min(firstNumber, secondNumber)...max(firstNumber, secondNumber)
    }
}

public enum DisulfideFinder {

    /// Longest SG to SG separation accepted as a bond, in angstroms.
    ///
    /// A disulfide is 2.03 A give or take 0.02 in a well-refined structure.
    /// 2.5 A is the usual working ceiling and is deliberately generous: it
    /// admits strained and poorly refined examples rather than silently
    /// dropping a real bond, and the alternative failure (inventing a bond
    /// between two free cysteines that happen to be close) is guarded by the
    /// one-bond-per-sulfur rule rather than by a tight cutoff.
    public static let maximumDistance: Float = 2.5

    /// Shortest separation accepted.
    ///
    /// Below this the two atoms are not two atoms: they are a modelling
    /// artefact, an unmerged altloc, or a file with the same atom twice. A
    /// "bond" of 0.8 A is not a strained disulfide, it is a broken input.
    public static let minimumDistance: Float = 1.6

    /// Find the disulfide bonds in a structure.
    ///
    /// - Parameters:
    ///   - store: the atoms.
    ///   - model: which model to search. Defaults to the first present, because
    ///     searching an NMR ensemble as one bag of atoms pairs a sulfur with
    ///     its own image in another model.
    /// - Returns: pairs, shortest first.
    public static func find(in store: AtomStore, model: Int? = nil) -> [Disulfide] {
        guard !store.isEmpty else { return [] }
        let targetModel = model ?? store.models.first ?? 0

        // One SG per cysteine residue: the highest-occupancy altloc.
        //
        // Keyed by chain and author number rather than by index, which is what
        // collapses the altlocs. Insertion codes are not in the store, so two
        // residues numbered 52 and 52A in the same chain would collide; that
        // is recorded rather than silently handled, since no fixture exercises
        // it and inventing an untested key format would be worse.
        struct Key: Hashable {
            let chain: String
            let number: Int
        }
        var best: [Key: (index: Int, occupancy: Float)] = [:]

        for index in 0..<store.count {
            guard store.model[index] == targetModel else { continue }
            guard store.atomName[index] == "SG" else { continue }
            // CYS covalently bonded to a metal or a ligand is still CYS; the
            // residue name is the right filter and the atom name does the rest.
            guard store.residueName[index] == "CYS" else { continue }

            let key = Key(chain: store.chainID[index], number: store.authorNumber[index])
            let occupancy = store.occupancy[index]
            if let existing = best[key], existing.occupancy >= occupancy { continue }
            best[key] = (index, occupancy)
        }

        let sulfurs = best.map { (key: $0.key, index: $0.value.index) }
        guard sulfurs.count >= 2 else { return [] }

        // Every candidate pair inside the window, shortest first.
        var candidates: [(distance: Float, a: Int, b: Int)] = []
        for i in 0..<sulfurs.count {
            for j in (i + 1)..<sulfurs.count {
                let ai = sulfurs[i].index
                let bi = sulfurs[j].index
                let dx = store.x[ai] - store.x[bi]
                let dy = store.y[ai] - store.y[bi]
                let dz = store.z[ai] - store.z[bi]
                let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
                guard distance <= maximumDistance, distance >= minimumDistance else { continue }
                candidates.append((distance, i, j))
            }
        }
        candidates.sort { $0.distance < $1.distance }

        // Greedy matching: shortest pair wins, and both sulfurs are then spent.
        //
        // Greedy rather than optimal on purpose. A maximum-weight matching
        // would be the general answer and would differ from this only when one
        // sulfur has two partners inside 2.5 A, which is a structure with a
        // modelling problem in it. Choosing the shorter contact there is both
        // the chemically likelier bond and the one a person would pick.
        var used = Set<Int>()
        var found: [Disulfide] = []
        for candidate in candidates {
            guard !used.contains(candidate.a), !used.contains(candidate.b) else { continue }
            used.insert(candidate.a)
            used.insert(candidate.b)
            let first = sulfurs[candidate.a].key
            let second = sulfurs[candidate.b].key
            // Ordered so the same bond always reads the same way.
            let ordered =
                (first.chain, first.number) <= (second.chain, second.number)
                ? (first, second) : (second, first)
            found.append(
                Disulfide(
                    firstChain: ordered.0.chain, firstNumber: ordered.0.number,
                    secondChain: ordered.1.chain, secondNumber: ordered.1.number,
                    distance: candidate.distance))
        }
        return found.sorted { $0.distance < $1.distance }
    }
}
