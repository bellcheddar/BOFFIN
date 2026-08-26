//  AtomStore.swift
//  BoffinStructure
//
//  Structure domain, parsing and geometry.
//
//  Licensing: PLIP is GPL v2 and is never linked or ported. The interaction
//  profiler is a clean-room Swift implementation of published geometric
//  criteria. See Docs/ATTRIBUTIONS.md.

import BoffinCore
import Foundation

/// Atom records in struct-of-arrays layout.
///
/// Parallel arrays rather than an array of structs: neighbour search, geometry
/// and rendering all sweep single attributes over every atom, and a 100k-atom
/// assembly on a phone cannot afford the cache behaviour of the array-of-structs
/// alternative. 7K00, the ribosome fixture, is 127,000 atoms.
public struct AtomStore: Sendable {
    public private(set) var x: [Float]
    public private(set) var y: [Float]
    public private(set) var z: [Float]
    /// Element symbol, as the file writes it.
    public private(set) var element: [String]
    /// Atom name within the residue: `CA`, `OD1`.
    public private(set) var atomName: [String]
    /// Residue three-letter code.
    public private(set) var residueName: [String]
    /// PDB author residue number, which is what a paper quotes.
    public private(set) var authorNumber: [Int]
    /// PDB author chain identifier.
    public private(set) var chainID: [String]
    public private(set) var bFactor: [Float]
    public private(set) var occupancy: [Float]
    /// Alternate location indicator, empty when there is none.
    public private(set) var altLoc: [String]
    /// True for HETATM, false for ATOM.
    public private(set) var isHeteroatom: [Bool]
    /// Model number, for NMR ensembles.
    public private(set) var model: [Int]

    public var count: Int { x.count }
    public var isEmpty: Bool { x.isEmpty }

    public init() {
        x = []
        y = []
        z = []
        element = []
        atomName = []
        residueName = []
        authorNumber = []
        chainID = []
        bFactor = []
        occupancy = []
        altLoc = []
        isHeteroatom = []
        model = []
    }

    public mutating func append(
        x: Float, y: Float, z: Float, element: String, atomName: String,
        residueName: String, authorNumber: Int, chainID: String, bFactor: Float,
        occupancy: Float, altLoc: String, isHeteroatom: Bool, model: Int
    ) {
        self.x.append(x)
        self.y.append(y)
        self.z.append(z)
        self.element.append(element)
        self.atomName.append(atomName)
        self.residueName.append(residueName)
        self.authorNumber.append(authorNumber)
        self.chainID.append(chainID)
        self.bFactor.append(bFactor)
        self.occupancy.append(occupancy)
        self.altLoc.append(altLoc)
        self.isHeteroatom.append(isHeteroatom)
        self.model.append(model)
    }

    /// Distinct author chain identifiers, in the order they first appear.
    public var chains: [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for identifier in chainID where !seen.contains(identifier) {
            seen.insert(identifier)
            order.append(identifier)
        }
        return order
    }

    /// Model numbers present, ascending. More than one means an NMR ensemble.
    public var models: [Int] { Array(Set(model)).sorted() }

    /// The axis-aligned bounding box, for framing the camera.
    public var bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
        guard !isEmpty else { return nil }
        var low = SIMD3<Float>(x[0], y[0], z[0])
        var high = low
        for index in 1..<count {
            low = SIMD3(min(low.x, x[index]), min(low.y, y[index]), min(low.z, z[index]))
            high = SIMD3(max(high.x, x[index]), max(high.y, y[index]), max(high.z, z[index]))
        }
        return (low, high)
    }
}

public enum AtomStoreError: Error, Sendable {
    case noAtomSite
    case missingColumn(String)
}

extension AtomStore {

    /// Build from a decoded BinaryCIF file.
    ///
    /// - Parameters:
    ///   - file: a decoded structure.
    ///   - model: which model to take, or `nil` for the first one present.
    ///     An NMR ensemble holds twenty superimposed copies, and loading all of
    ///     them at once looks like a single very badly resolved structure.
    /// - Returns: the atoms of that model.
    /// - Throws: ``AtomStoreError`` when the file has no atom site table, or
    ///   when that table is missing a column the result would be meaningless
    ///   without.
    public static func from(
        _ file: BinaryCIFFile, model: Int? = nil
    ) throws -> AtomStore {
        guard let site = file["_atom_site"] else { throw AtomStoreError.noAtomSite }

        // `missingColumn` was declared for exactly this and never thrown, so
        // every column below reached for a fallback instead. Individually the
        // fallbacks look defensive; together they turn an unreadable file into
        // a successful load. A file whose coordinates failed to decode returns
        // an empty store and no error. One with no `label_comp_id` returns
        // atoms whose residues are all named "", so every selection matches
        // nothing. One with neither sequence-number column numbers every
        // residue 0, collapsing the whole chain into a single residue.
        //
        // These six are mandatory in mmCIF, so requiring them rejects broken
        // files without rejecting unusual ones. Everything not listed here
        // keeps its fallback deliberately: `occupancy` and `B_iso_or_equiv`
        // are genuinely optional, and a predicted model legitimately has no
        // `group_PDB`.
        for required in ["Cartn_x", "Cartn_y", "Cartn_z", "type_symbol",
                         "label_atom_id", "label_comp_id"] {
            guard site[required] != nil else {
                throw AtomStoreError.missingColumn(required)
            }
        }
        // Either member of these pairs will do; losing both is fatal in the
        // way described above, and the existing `??` chains hid it.
        guard site["auth_seq_id"] != nil || site["label_seq_id"] != nil else {
            throw AtomStoreError.missingColumn("auth_seq_id or label_seq_id")
        }
        guard site["auth_asym_id"] != nil || site["label_asym_id"] != nil else {
            throw AtomStoreError.missingColumn("auth_asym_id or label_asym_id")
        }

        let modelColumn = site["pdbx_PDB_model_num"]
        let wanted = model ?? modelColumn?.int(0) ?? 1

        var store = AtomStore()
        store.reserve(site.rowCount)

        for row in 0..<site.rowCount {
            let rowModel = modelColumn?.int(row) ?? 1
            guard rowModel == wanted else { continue }
            guard let px = site["Cartn_x"]?.double(row),
                let py = site["Cartn_y"]?.double(row),
                let pz = site["Cartn_z"]?.double(row)
            else { continue }

            store.append(
                x: Float(px), y: Float(py), z: Float(pz),
                element: site["type_symbol"]?.string(row) ?? "",
                atomName: site["label_atom_id"]?.string(row) ?? "",
                residueName: site["label_comp_id"]?.string(row) ?? "",
                // Author numbering, not label numbering. `label_seq_id` counts
                // from one along the entity and is not what any paper quotes;
                // `auth_seq_id` is the number on the page.
                authorNumber: site["auth_seq_id"]?.int(row)
                    ?? site["label_seq_id"]?.int(row) ?? 0,
                chainID: site["auth_asym_id"]?.string(row)
                    ?? site["label_asym_id"]?.string(row) ?? "",
                bFactor: Float(site["B_iso_or_equiv"]?.double(row) ?? 0),
                occupancy: Float(site["occupancy"]?.double(row) ?? 1),
                altLoc: site["label_alt_id"]?.string(row) ?? "",
                isHeteroatom: (site["group_PDB"]?.string(row) ?? "ATOM") == "HETATM",
                model: rowModel)
        }
        return store
    }

    mutating func reserve(_ capacity: Int) {
        x.reserveCapacity(capacity)
        y.reserveCapacity(capacity)
        z.reserveCapacity(capacity)
        element.reserveCapacity(capacity)
        atomName.reserveCapacity(capacity)
        residueName.reserveCapacity(capacity)
        authorNumber.reserveCapacity(capacity)
        chainID.reserveCapacity(capacity)
        bFactor.reserveCapacity(capacity)
        occupancy.reserveCapacity(capacity)
        altLoc.reserveCapacity(capacity)
        isHeteroatom.reserveCapacity(capacity)
        model.reserveCapacity(capacity)
    }
}

// MARK: - Alternate conformations

extension AtomStore {

    /// The atoms belonging to the conformation that should be analysed.
    ///
    /// A residue refined in two or three conformations is written as two or
    /// three copies of its atoms, each with an altloc code and a partial
    /// occupancy summing to about one. They are alternative models of ONE
    /// residue, not several residues, and every analysis that walks the atom
    /// list has to decide which copy it means.
    ///
    /// Deciding it by accident is the failure this exists to prevent, and it
    /// was a live one. `SecondaryStructureAssigner.backbones` assigned each
    /// backbone atom with `=` as it walked the file, so the LAST copy in file
    /// order won. File order is altloc code order, which has no relationship to
    /// occupancy: measured on PETase, 25 residues carry alternate CA positions
    /// and the last-wins rule takes the MINOR conformer in most of them,
    /// including residue 53, where it picks the 0.29-occupancy copy over two
    /// at 0.35.
    ///
    /// Worse in principle than in that measurement: nothing stopped the N
    /// coming from conformer A and the CA from conformer B. Those are two
    /// different molecules, and a peptide assembled from both has bond lengths
    /// and angles that exist in neither.
    ///
    /// The rule here is the conventional one: highest occupancy wins, and ties
    /// go to the alphabetically first altloc code, which is deterministic and
    /// matches what the depositor wrote first. Atoms with no altloc are always
    /// kept, since they are not alternatives to anything.
    ///
    /// - Returns: indices into this store, in their original order.
    public func primaryConformationIndices() -> [Int] {
        // Fast path: most structures have no alternate conformations at all,
        // and building a dictionary for them is pure cost.
        guard altLoc.contains(where: { !$0.isEmpty }) else {
            return Array(0..<count)
        }

        struct Key: Hashable {
            let model: Int
            let chain: String
            let number: Int
            let atom: String
        }

        var chosen: [Key: Int] = [:]
        for index in 0..<count where !altLoc[index].isEmpty {
            let key = Key(
                model: model[index], chain: chainID[index],
                number: authorNumber[index], atom: atomName[index])
            guard let incumbent = chosen[key] else {
                chosen[key] = index
                continue
            }
            if occupancy[index] > occupancy[incumbent] {
                chosen[key] = index
            } else if occupancy[index] == occupancy[incumbent],
                altLoc[index] < altLoc[incumbent]
            {
                chosen[key] = index
            }
        }

        let keep = Set(chosen.values)
        return (0..<count).filter { altLoc[$0].isEmpty || keep.contains($0) }
    }

    /// Whether this structure models any residue in more than one conformation.
    ///
    /// Worth surfacing rather than silently handling: a user looking at a
    /// disordered side chain should know the picture shows one of several
    /// refined possibilities.
    public var hasAlternateConformations: Bool {
        altLoc.contains { !$0.isEmpty }
    }
}
