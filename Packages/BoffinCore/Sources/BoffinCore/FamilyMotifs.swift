//  FamilyMotifs.swift
//  BoffinCore
//
//  Canonical sequence motifs for the families BOFFIN annotates.
//
//  These are the anchors that turn a raw delta-LLR into an interpretable call:
//  a mutation at the DFG aspartate means something a mutation at an arbitrary
//  surface residue does not. Hard rule 6 applies in full, so every motif here
//  carries its published definition and is tested against a protein whose
//  residue numbers are in the textbooks.
//
//  Detection is by sequence pattern with ORDERING CONSTRAINTS, not by pattern
//  alone. "HRD" occurs by chance roughly once per 8,000 residues, so on a large
//  protein an unconstrained search finds spurious hits and labels them with
//  great confidence. The catalytic motifs of a kinase occur in a fixed order
//  and within known separations, and requiring that is what makes the call
//  worth trusting.
//
//  What this deliberately does NOT do is derive KLIFS or GPCRdb numbering.
//  Both assign numbers by structure-based alignment against curated references,
//  and a number that is off by one through a helix bulge is invisible and would
//  be believed. Those tables are bundled (see Tools/data/fetch_family_tables.py)
//  and mapped, never recomputed.

import Foundation

/// A named, annotated region of sequence.
public struct Motif: Sendable, Hashable, Identifiable {
    public let name: String
    /// Inclusive residue range, zero-based.
    public let range: ClosedRange<Int>
    /// What this motif does, for the detail popover.
    public let role: String
    /// The residues actually matched, so a variant is visible rather than
    /// hidden behind the canonical name.
    public let matched: String

    public var id: String { "\(name):\(range.lowerBound)" }

    public init(name: String, range: ClosedRange<Int>, role: String, matched: String) {
        self.name = name
        self.range = range
        self.role = role
        self.matched = matched
    }
}

/// Families BOFFIN can annotate motifs for.
public enum MotifFamily: String, CaseIterable, Sendable {
    case proteinKinase
    case classAGPCR
}

public enum FamilyMotifs {

    // MARK: - Protein kinases

    /// Annotate the catalytic machinery of a protein kinase.
    ///
    /// Anchors, and where the published definitions put them (verified against
    /// human CDK2, UniProt P24941, whose numbering is textbook):
    ///
    /// | Motif | CDK2 | Role |
    /// |---|---|---|
    /// | Glycine-rich loop `GxGxxG` | G11 to G16 | positions ATP phosphates |
    /// | beta-3 lysine (VAIK) | K33 | pairs with the alpha-C glutamate |
    /// | alpha-C glutamate | E51 | salt bridge marking the active conformation |
    /// | gatekeeper | F80 | controls access to the back pocket |
    /// | catalytic HRD | H125 to D127 | the catalytic aspartate |
    /// | DFG | D145 to G147 | chelates magnesium; in/out defines the state |
    ///
    /// Returns an empty array when the ordering constraints are not satisfied,
    /// rather than reporting whichever fragments matched. A partial kinase
    /// annotation is worse than none: it looks like a positive identification.
    public static func proteinKinase(in sequence: ProteinSequence) -> [Motif] {
        let letters = Array(sequence.letters)
        guard letters.count >= 100 else { return [] }

        // HRD and DFG are the two anchors everything else is placed against.
        // Both tolerate the documented variants: HRD is HRD/YRD/HGD and DFG is
        // DFG/DLG/DWG. Measured across the 521 human kinases in KLIFS, position
        // 68 is H in 443 and Y in 45, and position 82 is F in 424 and L in 51,
        // so a strict HRD/DFG search would silently miss about a tenth of the
        // kinome.
        guard
            let hrd = firstMatch(
                letters, at: 90..., pattern: [["H", "Y"], ["R", "G", "C", "L"], ["D"]]),
            let dfg = firstMatch(
                letters, at: (hrd + 3)..., pattern: [["D", "G"], ["F", "L", "W", "Y"], ["G"]])
        else { return [] }

        // The activation loop is short. In every human kinase the DFG follows
        // the HRD by roughly 15 to 40 residues, so a hit outside that window is
        // a coincidence rather than a kinase.
        let separation = dfg - hrd
        guard (12...45).contains(separation) else { return [] }

        var motifs: [Motif] = []

        if let loop = firstMatch(
            letters, at: 0..., pattern: [["G"], anyResidue, ["G"], anyResidue, anyResidue, ["G"]]),
            loop < hrd
        {
            motifs.append(
                Motif(
                    name: "Glycine-rich loop",
                    range: loop...(loop + 5),
                    role: "Positions the ATP phosphates. Also called the P-loop.",
                    matched: String(letters[loop...(loop + 5)])))
        }

        // The beta-3 lysine is the K of the VAIK motif, matched as a pattern
        // rather than as "the first lysine after the glycine-rich loop". The
        // positional version found CDK2's K24 instead of its K33: lysine is
        // common, and picking the first one in a window is luck rather than a
        // definition. VAIK is the published anchor and tolerates the usual
        // hydrophobic substitutions at the first and third positions.
        let hydrophobic = ["V", "I", "L", "M", "A", "C"]
        let searchFrom = motifs.first.map { $0.range.upperBound + 1 } ?? 10
        if let vaik = firstMatch(
            letters, at: searchFrom...,
            pattern: [hydrophobic, ["A", "G", "S"], hydrophobic, ["K"]]),
            vaik + 3 < hrd
        {
            let lysine = vaik + 3
            motifs.append(
                Motif(
                    name: "beta-3 lysine",
                    range: lysine...lysine,
                    role: "Pairs with the alpha-C glutamate to position ATP. "
                        + "The K of the VAIK motif.",
                    matched: String(letters[vaik...lysine])))
        }

        motifs.append(
            Motif(
                name: "Catalytic HRD",
                range: hrd...(hrd + 2),
                role: "The catalytic aspartate that accepts the substrate hydroxyl proton.",
                matched: String(letters[hrd...(hrd + 2)])))

        motifs.append(
            Motif(
                name: "DFG",
                range: dfg...(dfg + 2),
                role: "Chelates the catalytic magnesium. Its in or out position "
                    + "defines the active state and is what type II inhibitors exploit.",
                matched: String(letters[dfg...(dfg + 2)])))

        return motifs.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Class A GPCRs

    /// Annotate the conserved class A GPCR micro-switches.
    ///
    /// | Motif | GPCRdb | Role |
    /// |---|---|---|
    /// | `D[ER]Y` | 3x49 to 3x51 | ionic lock; constrains the inactive state |
    /// | `CWxP` | 6x47 to 6x50 | rotamer toggle on TM6 |
    /// | `NPxxY` | 7x49 to 7x53 | repacks on activation |
    ///
    /// Ordering is required: DRY on TM3 precedes CWxP on TM6, which precedes
    /// NPxxY on TM7. Each of these patterns occurs by chance often enough that
    /// an unordered search on a 400-residue receptor is not evidence.
    public static func classAGPCR(in sequence: ProteinSequence) -> [Motif] {
        let letters = Array(sequence.letters)
        guard letters.count >= 250 else { return [] }

        guard
            let dry = firstMatch(letters, at: 80..., pattern: [["D", "E"], ["R"], ["Y", "H"]]),
            let cwxp = firstMatch(
                letters, at: (dry + 40)..., pattern: [["C"], ["W"], anyResidue, ["P"]]),
            let npxxy = firstMatch(
                letters, at: (cwxp + 8)...,
                pattern: [["N"], ["P"], anyResidue, anyResidue, ["Y"]])
        else { return [] }

        return [
            Motif(
                name: "D[ER]Y",
                range: dry...(dry + 2),
                role: "The ionic lock at the cytoplasmic end of TM3 (GPCRdb 3x49 to 3x51). "
                    + "Constrains the inactive state.",
                matched: String(letters[dry...(dry + 2)])),
            Motif(
                name: "CWxP",
                range: cwxp...(cwxp + 3),
                role: "Rotamer toggle switch on TM6 (GPCRdb 6x47 to 6x50).",
                matched: String(letters[cwxp...(cwxp + 3)])),
            Motif(
                name: "NPxxY",
                range: npxxy...(npxxy + 4),
                role: "TM7 motif that repacks against TM3 on activation "
                    + "(GPCRdb 7x49 to 7x53).",
                matched: String(letters[npxxy...(npxxy + 4)])),
        ]
    }

    /// Detect motifs for whichever families match, most specific first.
    public static func all(in sequence: ProteinSequence) -> [MotifFamily: [Motif]] {
        var found: [MotifFamily: [Motif]] = [:]
        let kinase = proteinKinase(in: sequence)
        if !kinase.isEmpty { found[.proteinKinase] = kinase }
        let gpcr = classAGPCR(in: sequence)
        if !gpcr.isEmpty { found[.classAGPCR] = gpcr }
        return found
    }

    /// Motifs as a span track on the shared ruler.
    public static func track(_ motifs: [Motif]) -> AnyResidueTrack? {
        guard !motifs.isEmpty else { return nil }
        return AnyResidueTrack(
            id: TrackID("motifs"),
            title: "Family motifs",
            kind: .span,
            values: .spans(
                motifs.map {
                    TrackSpan(start: $0.range.lowerBound, end: $0.range.upperBound, label: $0.name)
                }),
            colourScheme: .solid)
    }

    // MARK: - Matching

    /// Any residue: the `x` in a motif pattern.
    private static let anyResidue: [String] = []

    /// First index at or after `range.lowerBound` where every pattern position
    /// matches one of its permitted residues. An empty option list matches any
    /// residue.
    private static func firstMatch(
        _ letters: [Character],
        at range: PartialRangeFrom<Int>,
        pattern: [[String]]
    ) -> Int? {
        let start = max(0, range.lowerBound)
        guard letters.count >= pattern.count else { return nil }
        let last = letters.count - pattern.count
        guard start <= last else { return nil }

        for index in start...last {
            var matched = true
            for (offset, options) in pattern.enumerated() {
                if options.isEmpty { continue }
                if !options.contains(String(letters[index + offset])) {
                    matched = false
                    break
                }
            }
            if matched { return index }
        }
        return nil
    }
}
