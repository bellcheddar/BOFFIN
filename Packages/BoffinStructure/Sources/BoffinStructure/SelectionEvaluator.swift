//  SelectionEvaluator.swift
//  BoffinStructure
//
//  Evaluating a parsed selection against an `AtomStore`.
//
//  `within` is the only expensive operator, and it is the one worth getting
//  right twice: naively it is a comparison against every atom of the right-hand
//  selection for every atom of the store, which on the ribosome fixture is
//  127,000 times a few thousand. A uniform grid over the target atoms turns it
//  into a look at the twenty-seven cells around each candidate.

import Foundation

/// Which atoms a selection picks out.
public struct AtomSelection: Sendable, Hashable {
    public let indices: Set<Int>

    public init(_ indices: Set<Int>) { self.indices = indices }

    public var count: Int { indices.count }
    public var isEmpty: Bool { indices.isEmpty }
    public var sorted: [Int] { indices.sorted() }
}

public enum SelectionEvaluator {

    /// Residues classed as solvent.
    ///
    /// Water and the common cryoprotectants and buffer components. This is a
    /// judgement about what a user means by "solvent" rather than a fact, so it
    /// is one visible list instead of a condition buried in a filter.
    public static let solventResidues: Set<String> = [
        "HOH", "WAT", "DOD", "H2O", "SOL",
        "GOL", "EDO", "PEG", "PG4", "MPD", "DMS", "TRS", "MES", "EPE", "ACT",
        "SO4", "PO4", "CL", "NA", "K", "MG", "CA", "ZN",
    ]

    /// Ions and metals, which are solvent to some questions and not to others.
    public static let metalResidues: Set<String> = [
        "NA", "K", "MG", "CA", "ZN", "FE", "FE2", "MN", "CU", "CU1", "NI", "CO",
        "CD", "HG", "MO", "W", "SE",
    ]

    /// Backbone atom names, in the sense a structural biologist means: N, CA, C
    /// and O. Not CB, which is where a side chain begins.
    public static let backboneAtoms: Set<String> = ["N", "CA", "C", "O", "OXT"]

    /// Modified residues that belong to a chain even when deposited as HETATM.
    ///
    /// The distinction this set exists to draw. A residue name in
    /// ``polymerResidues`` can appear as a HETATM for two opposite reasons:
    ///
    /// - it is a MODIFIED residue in the middle of a chain, which the PDB
    ///   records as HETATM because it is not one of the twenty. It is polymer.
    /// - it is a FREE amino acid bound as a ligand, an alanine or a glycine
    ///   sitting in a site. It is not polymer, and counting it as one would put
    ///   a ligand into the protein.
    ///
    /// Only these names take the exception. The standard twenty appearing as
    /// HETATM are ligands and stay out.
    ///
    /// This was `== "MSE"` alone until 2026-08-26, so selenomethionine was
    /// rescued and every other modified residue was not. Phosphoserine is the
    /// one that matters most in practice: SEP, TPO and PTR are deposited as
    /// HETATM and are the whole point of a kinase-substrate structure, so a
    /// phosphopeptide lost its phosphoresidues from every polymer selection.
    /// The cartoon breaks at the modified residue and a pocket selection
    /// returns a hole exactly where the chemistry is.
    public static let modifiedPolymerResidues: Set<String> = [
        "MSE", "SEC", "PYL", "HYP", "SEP", "TPO", "PTR", "CSO", "CME",
    ]

    /// The twenty standard residues plus the common modified ones a chain can
    /// contain without ceasing to be a polymer.
    public static let polymerResidues: Set<String> = [
        "ALA", "ARG", "ASN", "ASP", "CYS", "GLN", "GLU", "GLY", "HIS", "ILE",
        "LEU", "LYS", "MET", "PHE", "PRO", "SER", "THR", "TRP", "TYR", "VAL",
        "MSE", "SEC", "PYL", "HYP", "SEP", "TPO", "PTR", "CSO", "CME",
        "A", "C", "G", "U", "DA", "DC", "DG", "DT", "DI", "N",
    ]

    /// Evaluate a selection.
    public static func evaluate(
        _ selection: Selection, in store: AtomStore
    ) -> AtomSelection {
        AtomSelection(indices(selection, store))
    }

    private static func indices(_ selection: Selection, _ store: AtomStore) -> Set<Int> {
        switch selection {
        case .all:
            return Set(0..<store.count)
        case .none:
            return []
        case .chain(let names):
            let wanted = Set(names)
            return filter(store) { wanted.contains(store.chainID[$0]) }
        case .residueNumbers(let ranges):
            return filter(store) { index in
                ranges.contains { $0.contains(store.authorNumber[index]) }
            }
        case .residueNames(let names):
            let wanted = Set(names)
            return filter(store) { wanted.contains(store.residueName[$0].uppercased()) }
        case .atomNames(let names):
            let wanted = Set(names)
            return filter(store) { wanted.contains(store.atomName[$0].uppercased()) }
        case .elements(let symbols):
            let wanted = Set(symbols)
            return filter(store) { wanted.contains(store.element[$0].uppercased()) }
        case .alternateLocations(let codes):
            let wanted = Set(codes)
            return filter(store) { wanted.contains(store.altLoc[$0]) }
        case .category(let category):
            return categoryIndices(category, store)
        case .numericProperty(let property, let comparison, let value):
            return filter(store) { index in
                let measured =
                    property == .bFactor
                    ? Double(store.bFactor[index]) : Double(store.occupancy[index])
                return comparison.holds(measured, value)
            }
        case .not(let inner):
            let picked = indices(inner, store)
            return filter(store) { !picked.contains($0) }
        case .and(let left, let right):
            return indices(left, store).intersection(indices(right, store))
        case .or(let left, let right):
            return indices(left, store).union(indices(right, store))
        case .within(let distance, let left, let right):
            return withinIndices(
                distance: distance, candidates: indices(left, store),
                targets: indices(right, store), store: store)
        case .byResidue(let inner):
            return expandToResidues(indices(inner, store), store)
        }
    }

    private static func filter(
        _ store: AtomStore, _ predicate: (Int) -> Bool
    ) -> Set<Int> {
        var result: Set<Int> = []
        for index in 0..<store.count where predicate(index) { result.insert(index) }
        return result
    }

    private static func categoryIndices(
        _ category: Selection.Category, _ store: AtomStore
    ) -> Set<Int> {
        switch category {
        case .polymer:
            return filter(store) {
                polymerResidues.contains(store.residueName[$0].uppercased())
                    && !store.isHeteroatom[$0]
                    || (store.isHeteroatom[$0]
                        && modifiedPolymerResidues.contains(
                            store.residueName[$0].uppercased()))
            }
        case .solvent:
            return filter(store) { solventResidues.contains(store.residueName[$0].uppercased()) }
        case .metal:
            return filter(store) { metalResidues.contains(store.residueName[$0].uppercased()) }
        case .hydrogen:
            return filter(store) { store.element[$0].uppercased() == "H" }
        case .backbone:
            return filter(store) {
                !store.isHeteroatom[$0] && backboneAtoms.contains(store.atomName[$0].uppercased())
            }
        case .sidechain:
            return filter(store) {
                !store.isHeteroatom[$0]
                    && polymerResidues.contains(store.residueName[$0].uppercased())
                    && !backboneAtoms.contains(store.atomName[$0].uppercased())
            }
        case .organic:
            // A ligand: a heteroatom group that is neither solvent nor a metal
            // nor part of the polymer. This is what "organic" means in practice
            // to somebody looking at a binding site, and it is a definition
            // rather than a measurement, so it lives in one place.
            return filter(store) { index in
                let name = store.residueName[index].uppercased()
                return store.isHeteroatom[index] && !solventResidues.contains(name)
                    && !metalResidues.contains(name) && !polymerResidues.contains(name)
                    && store.element[index].uppercased() != "H"
            }
        }
    }

    /// Every atom of any residue the selection touches.
    static func expandToResidues(_ picked: Set<Int>, _ store: AtomStore) -> Set<Int> {
        guard !picked.isEmpty else { return [] }
        var keys: Set<String> = []
        for index in picked {
            keys.insert("\(store.chainID[index])\u{1}\(store.authorNumber[index])")
        }
        return filter(store) { index in
            keys.contains("\(store.chainID[index])\u{1}\(store.authorNumber[index])")
        }
    }

    /// Candidates within `distance` of any target atom.
    ///
    /// A uniform grid over the TARGETS, with a cell the size of the cutoff, so
    /// each candidate looks at twenty-seven cells rather than at every target.
    /// The naive form is fine for a ligand and quadratic for a ribosome.
    static func withinIndices(
        distance: Double, candidates: Set<Int>, targets: Set<Int>, store: AtomStore
    ) -> Set<Int> {
        guard !candidates.isEmpty, !targets.isEmpty, distance > 0 else { return [] }
        let cutoff = Float(distance)
        let cell = max(cutoff, 0.001)

        var grid: [SIMD3<Int32>: [Int]] = [:]
        func key(_ index: Int) -> SIMD3<Int32> {
            SIMD3(
                Int32((store.x[index] / cell).rounded(.down)),
                Int32((store.y[index] / cell).rounded(.down)),
                Int32((store.z[index] / cell).rounded(.down)))
        }
        for target in targets { grid[key(target), default: []].append(target) }

        let squared = cutoff * cutoff
        var result: Set<Int> = []
        for candidate in candidates {
            let home = key(candidate)
            var found = false
            for dx in -1...1 where !found {
                for dy in -1...1 where !found {
                    for dz in -1...1 where !found {
                        let neighbours =
                            grid[SIMD3(home.x + Int32(dx), home.y + Int32(dy), home.z + Int32(dz))]
                            ?? []
                        for target in neighbours {
                            let deltaX = store.x[candidate] - store.x[target]
                            let deltaY = store.y[candidate] - store.y[target]
                            let deltaZ = store.z[candidate] - store.z[target]
                            if deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ <= squared {
                                found = true
                                break
                            }
                        }
                    }
                }
            }
            if found { result.insert(candidate) }
        }
        return result
    }
}
