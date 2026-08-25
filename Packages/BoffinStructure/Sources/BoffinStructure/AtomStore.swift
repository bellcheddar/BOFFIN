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
    /// - Throws: ``AtomStoreError`` when the file has no atom site table.
    public static func from(
        _ file: BinaryCIFFile, model: Int? = nil
    ) throws -> AtomStore {
        guard let site = file["_atom_site"] else { throw AtomStoreError.noAtomSite }

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
