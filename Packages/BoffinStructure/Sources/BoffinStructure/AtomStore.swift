//  AtomStore.swift
//  BoffinStructure
//
//  Structure domain, parsing and geometry.
//
//  Phase 0 establishes the module boundary. Phase 7 supplies the mmCIF and
//  BinaryCIF parsers, Phase 8 the selection language, and Phase 9 the
//  clean-room interaction profiler.
//
//  Licensing: PLIP is GPL v2 and is never linked or ported. The interaction
//  profiler is a clean-room Swift implementation of published geometric
//  criteria. See Docs/ATTRIBUTIONS.md.

import BoffinCore

/// Atom records in struct-of-arrays layout.
///
/// Parallel arrays rather than an array of structs: neighbour search, geometry
/// and rendering all sweep single attributes over every atom, and a 100k-atom
/// assembly on a phone cannot afford the cache behaviour of the array-of-structs
/// alternative.
public struct AtomStore: Sendable {
    public private(set) var x: [Float]
    public private(set) var y: [Float]
    public private(set) var z: [Float]

    public var count: Int { x.count }

    public init() {
        self.x = []
        self.y = []
        self.z = []
    }
}
