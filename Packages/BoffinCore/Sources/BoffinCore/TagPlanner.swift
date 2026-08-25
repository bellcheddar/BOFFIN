//  TagPlanner.swift
//  BoffinCore
//
//  Phase 6: where to put the tag, which protease site to use, and the check
//  that matters more than either.
//
//  The check that matters
//  ----------------------
//  A cleavable tag is a protease recognition sequence deliberately placed at one
//  end of a construct. If the SAME sequence occurs inside the protein, the
//  protease cuts there too, and the result is a preparation that looks like
//  degradation and gets blamed on the sample. It is entirely avoidable and it is
//  the one thing here a computer should never let a person get wrong, so every
//  proposal is scanned and a site that occurs internally is refused rather than
//  ranked lower.

import Foundation

/// A protease used to remove an affinity tag.
public struct Protease: Sendable, Hashable, Identifiable {
    public let name: String
    /// The recognition sequence as one-letter codes, in the order it is written
    /// in the literature.
    public let recognition: String
    /// Zero-based index of the residue AFTER which the protease cuts.
    public let cutAfter: Int
    /// What is left on the protein after cleavage.
    public let scar: String
    public let note: String

    public var id: String { name }

    public init(
        name: String, recognition: String, cutAfter: Int, scar: String, note: String
    ) {
        self.name = name
        self.recognition = recognition
        self.cutAfter = cutAfter
        self.scar = scar
        self.note = note
    }

    /// TEV protease, ENLYFQ/G or ENLYFQ/S.
    ///
    /// Cuts between Q and G. The glycine is retained on the protein, so TEV
    /// leaves a one-residue scar. Highly specific and the usual default.
    public static let tev = Protease(
        name: "TEV",
        recognition: "ENLYFQG",
        cutAfter: 5,
        scar: "G",
        note: "Cuts between Q and G, leaving a single glycine. Works at 4 C, "
            + "which matters for anything that will not survive room temperature.")

    /// HRV 3C, also sold as PreScission. LEVLFQ/GP.
    public static let hrv3C = Protease(
        name: "HRV 3C",
        recognition: "LEVLFQGP",
        cutAfter: 5,
        scar: "GP",
        note: "Cuts between Q and G, leaving Gly-Pro. Efficient at 4 C and "
            + "available as a GST fusion that can be removed with the tag.")

    /// Thrombin, LVPR/GS.
    ///
    /// Listed last on purpose: its specificity is the loosest of the three and
    /// secondary cleavage inside the protein is a known failure.
    public static let thrombin = Protease(
        name: "Thrombin",
        recognition: "LVPRGS",
        cutAfter: 3,
        scar: "GS",
        note: "Cuts between R and G. The least specific of the three: secondary "
            + "cleavage elsewhere in the protein is a documented risk, so prefer "
            + "TEV or 3C unless there is a reason not to.")

    public static let all: [Protease] = [.tev, .hrv3C, .thrombin]
}

/// Which end of the construct the tag goes on.
public enum TagTerminus: String, Sendable, Hashable, Codable {
    case aminoTerminal = "N"
    case carboxyTerminal = "C"

    public var name: String {
        switch self {
        case .aminoTerminal: "N-terminal"
        case .carboxyTerminal: "C-terminal"
        }
    }
}

/// A tagging recommendation for one construct.
public struct TagPlan: Sendable, Hashable {
    public let terminus: TagTerminus
    /// Why that end, in the order the reasons were applied.
    public let rationale: [String]
    /// Proteases whose recognition sequence does NOT occur inside the construct.
    public let usableProteases: [Protease]
    /// Proteases refused because their site occurs internally, with where.
    public let refusedProteases: [(protease: Protease, position: Int)]

    public static func == (lhs: TagPlan, rhs: TagPlan) -> Bool {
        lhs.terminus == rhs.terminus && lhs.rationale == rhs.rationale
            && lhs.usableProteases == rhs.usableProteases
            && lhs.refusedProteases.map(\.protease) == rhs.refusedProteases.map(\.protease)
            && lhs.refusedProteases.map(\.position) == rhs.refusedProteases.map(\.position)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(terminus)
        hasher.combine(rationale)
        hasher.combine(usableProteases)
    }
}

public enum TagPlanner {

    /// Recommend a terminus and a protease for a construct.
    ///
    /// - Parameters:
    ///   - construct: the construct's residues, already truncated.
    ///   - hasSignalPeptide: whether the full-length protein carries one.
    ///   - startsDisordered: whether the construct's own N-terminal residues are
    ///     predicted disordered.
    ///   - endsDisordered: the same at the C terminus.
    /// - Returns: the plan, including any protease refused for cutting inside.
    public static func plan(
        construct: [AminoAcid],
        hasSignalPeptide: Bool,
        startsDisordered: Bool,
        endsDisordered: Bool
    ) -> TagPlan {
        var rationale: [String] = []
        var terminus: TagTerminus

        if hasSignalPeptide {
            // A signal peptide must remain the first thing the ribosome makes.
            // An N-terminal tag either blocks recognition or is removed with the
            // peptide, and both outcomes waste a construct.
            terminus = .carboxyTerminal
            rationale.append(
                "The protein carries a signal peptide, which has to stay at the very "
                    + "N terminus, so an N-terminal tag would either block secretion or "
                    + "be cleaved off with it.")
        } else if startsDisordered && !endsDisordered {
            terminus = .aminoTerminal
            rationale.append(
                "The N terminus is predicted disordered, so a tag there is less likely "
                    + "to perturb the fold than one against an ordered C terminus.")
        } else if endsDisordered && !startsDisordered {
            terminus = .carboxyTerminal
            rationale.append(
                "The C terminus is predicted disordered, so a tag there is less likely "
                    + "to perturb the fold than one against an ordered N terminus.")
        } else {
            terminus = .aminoTerminal
            rationale.append(
                "Neither terminus is clearly preferable from the prediction, so this is "
                    + "the conventional default rather than a recommendation: "
                    + "N-terminal tags are easier to clone and their removal leaves a "
                    + "smaller scar.")
        }

        // The check. Scan for each recognition sequence INSIDE the construct.
        let letters = String(construct.map(\.code))
        var usable: [Protease] = []
        var refused: [(protease: Protease, position: Int)] = []
        for protease in Protease.all {
            if let position = firstOccurrence(of: protease.recognition, in: letters) {
                refused.append((protease, position))
            } else {
                usable.append(protease)
            }
        }

        if usable.isEmpty {
            rationale.append(
                "Every protease considered cuts inside this construct, so the tag has to "
                    + "stay on, or be removed by a method that does not rely on a "
                    + "recognition sequence.")
        }

        return TagPlan(
            terminus: terminus, rationale: rationale,
            usableProteases: usable, refusedProteases: refused)
    }

    /// Zero-based index of the first occurrence of a motif, or `nil`.
    ///
    /// Written out rather than using `range(of:)` so it cannot be affected by
    /// locale or by Unicode canonical equivalence, neither of which has any
    /// meaning for a protein sequence.
    static func firstOccurrence(of motif: String, in sequence: String) -> Int? {
        let needle = Array(motif)
        let haystack = Array(sequence)
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in needle.indices where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
