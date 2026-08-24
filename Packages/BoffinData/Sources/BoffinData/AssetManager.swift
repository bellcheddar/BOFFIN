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
