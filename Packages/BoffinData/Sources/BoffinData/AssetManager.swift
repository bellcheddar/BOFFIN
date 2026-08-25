//  AssetManager.swift
//  BoffinData
//
//  Bundled reference data and downloadable assets: Pfam metadata, KLIFS and
//  GPCRdb numbering tables, the SIFTS slice, the embedding index and
//  pre-computed interaction profiles.
//
//  Phase 0 establishes the module boundary. Phase 5 supplies the family stores
//  and the embedding index.
//
//  Offline rule: nothing here may be required by a core path. Assets that have
//  not been downloaded degrade to an explicit unavailable state, never to a
//  blocking network call.

import BoffinCore

/// Where an asset lives and whether it is present.
public enum AssetAvailability: Sendable, Hashable {
    /// Shipped inside the app bundle: always present, no network involved.
    case bundled
    /// Delivered by Background Assets and present on disk.
    case downloaded
    /// Declared but not yet fetched. Features that need it must degrade
    /// cleanly and say so, rather than blocking.
    case notDownloaded
    /// Deliberately purged by the user to reclaim space.
    case purged
}

/// A downloadable data asset, with the size it costs and what stops working
/// without it.
///
/// The second field is the point. An asset catalogue that lists names and sizes
/// tells a user nothing about whether to fetch it, and a feature that simply
/// disappears when its asset is missing reads as a bug.
public struct BoffinAsset: Sendable, Hashable, Identifiable {
    public let id: String
    public let fileName: String
    public let approximateBytes: Int
    /// What the app cannot do until this is present, in the user's terms.
    public let enables: String

    public init(id: String, fileName: String, approximateBytes: Int, enables: String) {
        self.id = id
        self.fileName = fileName
        self.approximateBytes = approximateBytes
        self.enables = enables
    }
}

extension BoffinAsset {

    /// Pooled ESM-2 embeddings, one per UniProt accession in the PDB.
    public static let homologVectors = BoffinAsset(
        id: "homolog-vectors",
        fileName: "homolog_vectors.bin",
        approximateBytes: 34_800_000,
        enables: "Searching the PDB for proteins that resemble yours")

    /// Accession, entry, resolution, method and SEQRES for each index row.
    public static let homologMetadata = BoffinAsset(
        id: "homolog-metadata",
        fileName: "homolog_meta.bin",
        approximateBytes: 28_000_000,
        enables: "Naming homolog hits and aligning them to your sequence")

    /// SIFTS observed segments in SEQRES, UniProt and author numbering.
    public static let siftsSegments = BoffinAsset(
        id: "sifts-segments",
        fileName: "sifts_segments.bin",
        approximateBytes: 42_000_000,
        enables: "Reporting PDB author residue numbers and deposited constructs")

    /// Everything Phase 5 can download, in the order it is useful.
    ///
    /// The vectors and the metadata are a PAIR: an index loaded from one build's
    /// vectors and another's metadata would return correct similarities attached
    /// to the wrong proteins, so `HomologIndex` refuses to load a mismatched
    /// pair and they are always fetched together.
    public static let all: [BoffinAsset] = [
        .homologVectors, .homologMetadata, .siftsSegments,
    ]
}
