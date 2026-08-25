//  CrystalSymmetry.swift
//  BoffinStructure
//
//  Whether an entry came from a crystal, and which one.
//
//  This exists to answer one question before the viewer is asked to do
//  anything: does this structure HAVE symmetry mates? A crystal structure sits
//  in a lattice and its neighbours are what tell a biological interface apart
//  from an artefact of packing. An NMR ensemble and a predicted model have no
//  lattice at all, so offering to build their symmetry mates is offering
//  something that cannot exist.
//
//  Read from the entry rather than asked of the viewer. Mol* computes symmetry
//  as a lazily-attached model property rather than a plain field, so reaching
//  for it means reaching into a minified property system that has already
//  caught this project out once by exporting fewer names than its source
//  suggests. BOFFIN parses the same file itself, and `_cell` and `_symmetry`
//  are ordinary categories in it. One source, read directly.
//
//  A zero cell is how a file says "not from a crystal". Both categories are
//  frequently PRESENT and empty in NMR and predicted entries, so testing that
//  the category exists reports every AlphaFold model as crystallographic.

import Foundation

/// The crystallographic cell an entry declares, if it declares one.
public struct CrystalSymmetry: Sendable, Hashable {
    /// Hermann-Mauguin spacegroup name, as written, for example `P 21 21 21`.
    public let spacegroup: String?
    /// Cell edges in angstroms.
    public let a: Double
    public let b: Double
    public let c: Double
    /// Cell angles in degrees.
    public let alpha: Double
    public let beta: Double
    public let gamma: Double

    /// Whether this is a real cell rather than a placeholder.
    ///
    /// All three edges must be positive. A cell of zeroes is the conventional
    /// way a non-crystallographic entry fills in a category it has no values
    /// for, and it is written by enough tools that treating the category's
    /// presence as the test is simply wrong.
    public var isCrystallographic: Bool { a > 0 && b > 0 && c > 0 }

    /// Read the cell from a parsed entry.
    ///
    /// - Returns: `nil` when neither category is present at all, which is a
    ///   different fact from a present-but-empty cell and is worth keeping
    ///   distinct: one says the file never mentioned symmetry, the other says
    ///   it mentioned it and had nothing to say.
    public static func read(from file: BinaryCIFFile) -> CrystalSymmetry? {
        // Category names keep their leading underscore, as the file writes
        // them. Looking up "cell" finds nothing and returns a perfectly
        // plausible "this entry declares no symmetry" for every crystal
        // structure ever deposited.
        let cell = file["_cell"]
        let symmetry = file["_symmetry"]
        guard cell != nil || symmetry != nil else { return nil }

        func value(_ category: CIFCategory?, _ column: String) -> Double {
            category?.columns[column]?.double(0) ?? 0
        }

        // The spacegroup name's column is hyphenated in the dictionary and the
        // hyphen is part of the name, not a typo to be normalised away.
        let name =
            symmetry?.columns["space_group_name_H-M"]?.string(0)
            ?? symmetry?.columns["space_group_name_Hall"]?.string(0)

        return CrystalSymmetry(
            spacegroup: name.flatMap { $0.isEmpty ? nil : $0 },
            a: value(cell, "length_a"),
            b: value(cell, "length_b"),
            c: value(cell, "length_c"),
            alpha: value(cell, "angle_alpha"),
            beta: value(cell, "angle_beta"),
            gamma: value(cell, "angle_gamma"))
    }

    /// A sentence explaining why there are no symmetry mates, or `nil` when
    /// there are.
    ///
    /// Phrased as a fact about the structure rather than as a failure, because
    /// that is what it is. "Could not build symmetry mates" would send someone
    /// looking for a bug in an app that is working correctly.
    public var refusal: String? {
        guard !isCrystallographic else { return nil }
        return "This entry has no unit cell, so it has no symmetry mates. "
            + "Predicted models and NMR ensembles never do."
    }
}
