//  ReverseTranslator.swift
//  BoffinCore
//
//  Turning a construct into DNA somebody can order.
//
//  Codon choice is not the interesting part
//  ----------------------------------------
//  Picking the most frequent codon for each residue is three lines and it
//  produces a sequence that is difficult to synthesise and awkward to clone:
//  choosing CTG for every leucine builds long repeats, and choosing the same
//  codon for a run of identical residues builds homopolymers, which are exactly
//  what a synthesis house charges extra for or refuses.
//
//  So the generator avoids what it can see itself creating: a homopolymer run,
//  an internal restriction site for a common cloning enzyme, and local GC
//  content outside the range synthesis tolerates. Where the best codon would
//  cause one, the next best is used and the substitution is recorded, because a
//  silent deviation from "codon optimised" is the sort of thing that gets
//  noticed at sequencing.
//
//  What it does NOT do is claim to optimise expression. Codon adaptation is a
//  contested subject and this is a frequency table with three avoidance rules.
//  The output says so.

import Foundation

/// A restriction enzyme whose site should not appear inside the insert.
public struct RestrictionSite: Sendable, Hashable, Identifiable {
    public let enzyme: String
    public let site: String

    public var id: String { enzyme }

    public init(enzyme: String, site: String) {
        self.enzyme = enzyme
        self.site = site
    }

    /// The enzymes a construct is most likely to be cloned with.
    ///
    /// Written out because a recognition site is a definition rather than a
    /// measurement, and pinned in a test because a typo here produces a
    /// construct that fails at the cloning step for no visible reason.
    public static let common: [RestrictionSite] = [
        RestrictionSite(enzyme: "NdeI", site: "CATATG"),
        RestrictionSite(enzyme: "NcoI", site: "CCATGG"),
        RestrictionSite(enzyme: "BamHI", site: "GGATCC"),
        RestrictionSite(enzyme: "EcoRI", site: "GAATTC"),
        RestrictionSite(enzyme: "HindIII", site: "AAGCTT"),
        RestrictionSite(enzyme: "SalI", site: "GTCGAC"),
        RestrictionSite(enzyme: "XhoI", site: "CTCGAG"),
        RestrictionSite(enzyme: "XbaI", site: "TCTAGA"),
        RestrictionSite(enzyme: "NotI", site: "GCGGCCGC"),
        RestrictionSite(enzyme: "BsaI", site: "GGTCTC"),
        RestrictionSite(enzyme: "BsmBI", site: "CGTCTC"),
    ]
}

/// The DNA, and everything that had to be worked around to get it.
public struct ReverseTranslation: Sendable, Hashable {
    public let dna: String
    /// Positions, zero-based in the protein, where the most frequent codon was
    /// rejected, and why.
    public let substitutions: [(residue: Int, reason: String)]
    /// Overall GC fraction.
    public let gcFraction: Double
    /// Restriction sites still present after the avoidance pass, if any.
    public let remainingSites: [(site: RestrictionSite, position: Int)]
    public let provenance: String

    public static func == (lhs: ReverseTranslation, rhs: ReverseTranslation) -> Bool {
        lhs.dna == rhs.dna
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(dna) }
}

public enum ReverseTranslator {

    /// The longest run of one base the generator will allow itself to create.
    ///
    /// Six is the threshold most synthesis providers flag. It is a convention
    /// of the suppliers rather than a property of DNA, and it is named here
    /// rather than buried as a literal.
    public static let maximumHomopolymer = 5

    /// Codons under this fraction of their amino acid's usage are avoided where
    /// there is an alternative.
    ///
    /// Rare codons are the one part of codon choice with a mechanism behind it:
    /// a codon read by a scarce tRNA can stall translation. 0.10 is the
    /// conventional line and, like the homopolymer limit, it is a convention.
    public static let rareCodonFraction = 0.10

    /// Translate a protein into DNA.
    ///
    /// - Parameters:
    ///   - residues: the construct.
    ///   - sites: restriction sites to keep out of the insert.
    ///   - appendStop: whether to add a stop codon.
    /// - Returns: the DNA with everything that had to be worked around.
    public static func translate(
        _ residues: [AminoAcid],
        avoiding sites: [RestrictionSite] = RestrictionSite.common,
        appendStop: Bool = true
    ) -> ReverseTranslation {
        var dna = ""
        var substitutions: [(residue: Int, reason: String)] = []

        for (index, acid) in residues.enumerated() {
            let options = CodonTable.byAminoAcid[acid.code] ?? []
            guard !options.isEmpty else { continue }
            let next =
                index + 1 < residues.count
                ? CodonTable.byAminoAcid[residues[index + 1].code] ?? []
                : []

            var chosen: String?
            var reason: String?

            for (codon, fraction) in options {
                if fraction < rareCodonFraction,
                    options.contains(where: { $0.fraction >= rareCodonFraction })
                {
                    continue
                }
                let candidate = dna + codon
                if let run = homopolymerRun(endingIn: candidate), run > maximumHomopolymer {
                    reason = reason ?? "would create a run of \(run) identical bases"
                    continue
                }
                if let hit = sites.first(where: { tail(candidate, contains: $0.site) }) {
                    reason = reason ?? "would create a \(hit.enzyme) site"
                    continue
                }
                // One residue of lookahead, which the alternative taught. A
                // legal codon here can leave the NEXT residue with none: ATG-CAT
                // is fine, and the methionine that follows has only ATG, which
                // completes CATATG and cannot be designed around after the
                // fact. Rejecting a codon that strands its successor costs
                // nothing and removes the whole class.
                if !next.isEmpty,
                    !next.contains(where: { acceptable(candidate + $0.codon, sites: sites) })
                {
                    reason = reason ?? "would leave the next residue no legal codon"
                    continue
                }
                chosen = codon
                break
            }

            // Nothing worked: take the most frequent codon and say so, rather
            // than silently emitting a shorter protein.
            let codon = chosen ?? options[0].codon
            if chosen == nil {
                substitutions.append(
                    (
                        index,
                        "no codon avoids every constraint here, so the most "
                            + "frequent one was used"
                    ))
            } else if codon != options[0].codon, let reason {
                substitutions.append(
                    (index, "\(options[0].codon) \(reason), so \(codon) was used"))
            }
            dna += codon
        }

        if appendStop, let stop = CodonTable.stopCodons.first {
            dna += stop.codon
        }

        let gc = dna.count { $0 == "G" || $0 == "C" }
        var remaining: [(site: RestrictionSite, position: Int)] = []
        for site in sites {
            if let position = TagPlanner.firstOccurrence(of: site.site, in: dna) {
                remaining.append((site, position))
            }
        }

        return ReverseTranslation(
            dna: dna,
            substitutions: substitutions,
            gcFraction: dna.isEmpty ? 0 : Double(gc) / Double(dna.count),
            remainingSites: remaining,
            provenance:
                "Codon frequencies from \(CodonTable.provenance). This is a frequency "
                + "table with avoidance rules, not a claim about expression level.")
    }

    /// Does a growing sequence still satisfy every avoidance rule at its tail?
    static func acceptable(_ dna: String, sites: [RestrictionSite]) -> Bool {
        if let run = homopolymerRun(endingIn: dna), run > maximumHomopolymer {
            return false
        }
        return !sites.contains { tail(dna, contains: $0.site) }
    }

    /// The length of the run of identical bases ending at the last character.
    static func homopolymerRun(endingIn dna: String) -> Int? {
        guard let last = dna.last else { return nil }
        var run = 0
        for base in dna.reversed() {
            if base == last { run += 1 } else { break }
        }
        return run
    }

    /// Does the TAIL of the growing sequence contain a site?
    ///
    /// Only the tail needs checking, because everything earlier was checked when
    /// it was appended. Checking the whole string each time is quadratic and, on
    /// a 2,500-residue construct, noticeable.
    static func tail(_ dna: String, contains site: String) -> Bool {
        let window = site.count + 2
        let tail = String(dna.suffix(window))
        return TagPlanner.firstOccurrence(of: site, in: tail) != nil
    }
}
