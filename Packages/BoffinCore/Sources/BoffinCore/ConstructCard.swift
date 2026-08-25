//  ConstructCard.swift
//  BoffinCore
//
//  Phase 6's output: everything about one proposed construct, as text somebody
//  can paste into an order form, a lab notebook or a message to a colleague.
//
//  Plain text on purpose. A construct card is read by a person, forwarded, and
//  pasted into a supplier's web form, and every one of those survives plain text
//  better than it survives a PDF. The FASTA record at the end is there so the
//  same message can be dropped straight into another tool.
//
//  Everything on the card is either measured or stated as a convention. The one
//  number a card must never carry is a plausible-looking recommendation with no
//  provenance, because a card is exactly the artefact that gets forwarded with
//  the provenance stripped off.

import Foundation

/// A flexible or rigid linker between the tag and the protein.
///
/// These are conventions, not predictions, and the type says so: `provenance`
/// is not optional and every case fills it in.
public struct Linker: Sendable, Hashable, Identifiable {
    public let name: String
    public let sequence: String
    public let provenance: String

    public var id: String { name }
    public var length: Int { sequence.count }

    /// The standard flexible linker.
    public static let flexible = Linker(
        name: "Flexible (GGGGS)x2",
        sequence: "GGGGSGGGGS",
        provenance:
            "Glycine-serine repeats are the conventional flexible linker. Length is a "
            + "choice rather than a prediction: longer decouples the tag further and "
            + "adds disorder, shorter risks the tag contacting the protein.")

    /// A short one, when the terminus is already disordered.
    public static let short = Linker(
        name: "Short (GS)x2",
        sequence: "GSGS",
        provenance:
            "Enough to keep the tag off the fold when the terminus it joins is already "
            + "disordered, and no longer than it needs to be.")

    /// A rigid helical linker, for keeping two domains apart.
    public static let rigid = Linker(
        name: "Rigid (EAAAK)x2",
        sequence: "EAAAKEAAAK",
        provenance:
            "An alpha-helical linker, used when the tag and the protein must be held "
            + "apart rather than allowed to sample each other. Stiffer and more "
            + "immunogenic than glycine-serine.")

    public static let all: [Linker] = [.flexible, .short, .rigid]

    /// The conventional choice for a terminus.
    ///
    /// A recommendation, and labelled as one on the card: there is no measurement
    /// behind linker length, and presenting a convention as a result is exactly
    /// how a plausible number acquires false authority.
    public static func conventional(forDisorderedTerminus disordered: Bool) -> Linker {
        disordered ? .short : .flexible
    }
}

/// One construct, written out.
public struct ConstructCard: Sendable {
    public let proteinName: String
    /// One-based, inclusive, in the coordinates of the input sequence.
    public let range: ClosedRange<Int>
    public let residues: [AminoAcid]
    public let rationale: [String]
    public let tagPlan: TagPlan?
    public let linker: Linker?
    public let properties: SequenceProperties
    /// The scale the properties above were computed with.
    ///
    /// Stored WITH them rather than passed to `text`, because the two can
    /// disagree and nothing would catch it: the card would print the EMBOSS
    /// provenance line above numbers computed on the Bjellqvist scale, which
    /// differ by 0.2 to 0.5 pH units. A caller cannot get that wrong if it is
    /// not a separate argument.
    public let pKaScale: PKaScale
    public let precedentCount: Int
    /// Regions the solver was enforcing when it chose these boundaries.
    public let constraints: [ConstructConstraint]
    /// The insert, when DNA was asked for.
    public let dna: ReverseTranslation?

    public init(
        proteinName: String,
        range: ClosedRange<Int>,
        residues: [AminoAcid],
        rationale: [String],
        tagPlan: TagPlan?,
        linker: Linker?,
        properties: SequenceProperties,
        pKaScale: PKaScale,
        precedentCount: Int,
        constraints: [ConstructConstraint],
        dna: ReverseTranslation? = nil
    ) {
        self.proteinName = proteinName
        self.range = range
        self.residues = residues
        self.rationale = rationale
        self.tagPlan = tagPlan
        self.linker = linker
        self.properties = properties
        self.pKaScale = pKaScale
        self.precedentCount = precedentCount
        self.constraints = constraints
        self.dna = dna
    }

    public var letters: String { String(residues.map(\.code)) }

    /// The card as plain text.
    public func text() -> String {
        var lines: [String] = []
        lines.append("BOFFIN construct card")
        lines.append(String(repeating: "=", count: 21))
        lines.append("")
        lines.append("Protein   \(proteinName)")
        lines.append(
            "Construct residues \(range.lowerBound) to \(range.upperBound) "
                + "(\(residues.count) residues)")
        if precedentCount > 0 {
            lines.append(
                "Precedent \(precedentCount) deposited "
                    + (precedentCount == 1 ? "structure has" : "structures have")
                    + " comparable boundaries")
        }
        lines.append("")

        if !rationale.isEmpty {
            lines.append("Why these boundaries")
            lines.append(String(repeating: "-", count: 20))
            for reason in rationale { lines.append("  " + reason) }
            lines.append("")
        }

        if !constraints.isEmpty {
            lines.append("Regions kept intact")
            lines.append(String(repeating: "-", count: 19))
            for constraint in constraints.sorted(by: {
                $0.range.lowerBound < $1.range.lowerBound
            }) {
                lines.append(
                    "  \(constraint.label): "
                        + "\(constraint.range.lowerBound + 1) to "
                        + "\(constraint.range.upperBound + 1)"
                        + (constraint.kind == .signalPeptide ? " (removed)" : ""))
            }
            lines.append("")
        }

        if let tagPlan {
            lines.append("Tag")
            lines.append(String(repeating: "-", count: 3))
            lines.append("  Place the tag at the \(tagPlan.terminus.name) end.")
            for reason in tagPlan.rationale { lines.append("  " + reason) }
            if let linker {
                lines.append("  Linker \(linker.name): \(linker.sequence)")
                lines.append("    " + linker.provenance)
            }
            if let protease = tagPlan.usableProteases.first {
                lines.append(
                    "  Protease \(protease.name), \(protease.recognition), "
                        + "leaving \(protease.scar).")
                lines.append("    " + protease.note)
            }
            // The refusals go on the card, not just in the app. A card is what
            // gets forwarded, and the reason a protease was excluded is the part
            // most worth carrying with it.
            for refusal in tagPlan.refusedProteases {
                lines.append(
                    "  NOT \(refusal.protease.name): its site "
                        + "\(refusal.protease.recognition) occurs at residue "
                        + "\(refusal.position + 1) of this construct, so it would cut "
                        + "the protein as well as the tag.")
            }
            lines.append("")
        }

        lines.append("Computed properties, \(pKaScale.provenance)")
        lines.append(String(repeating: "-", count: 24))
        lines.append(String(format: "  Molecular weight  %.1f Da", properties.molecularWeight))
        lines.append(String(format: "  Isoelectric point %.2f", properties.isoelectricPoint))
        lines.append(
            String(
                format: "  Extinction 280 nm %.0f reduced, %.0f with cystines",
                properties.extinctionCoefficientReduced,
                properties.extinctionCoefficientCystine))
        lines.append(String(format: "  GRAVY             %.3f", properties.gravy))
        lines.append(String(format: "  Instability index %.2f", properties.instabilityIndex))
        if properties.nonCanonicalCount > 0 {
            lines.append(
                "  \(properties.nonCanonicalCount) non-canonical residues were excluded "
                    + "from every figure above.")
        }
        lines.append("")

        if let dna {
            lines.append("Insert DNA, \(dna.dna.count) bases")
            lines.append(String(repeating: "-", count: 22))
            lines.append(String(format: "  GC content %.1f%%", dna.gcFraction * 100))
            lines.append("  " + dna.provenance)
            if !dna.substitutions.isEmpty {
                lines.append(
                    "  \(dna.substitutions.count) codons are not the most frequent "
                        + "choice, to avoid a repeat or a cloning site:")
                for change in dna.substitutions.prefix(8) {
                    lines.append("    residue \(change.residue + 1): \(change.reason)")
                }
                if dna.substitutions.count > 8 {
                    lines.append(
                        "    and \(dna.substitutions.count - 8) more")
                }
            }
            for site in dna.remainingSites {
                lines.append(
                    "  WARNING: a \(site.site.enzyme) site (\(site.site.site)) remains "
                        + "at base \(site.position + 1) and could not be designed out.")
            }
            for chunk in dna.dna.chunked(60) { lines.append("  " + chunk) }
            lines.append("")
        }

        lines.append(">\(fastaHeader)")
        for chunk in letters.chunked(60) { lines.append(chunk) }
        lines.append("")
        lines.append(
            "Research use only. The boundaries are a proposal from sequence-derived "
                + "predictions, not a result.")
        return lines.joined(separator: "\n")
    }

    var fastaHeader: String {
        "\(proteinName) construct \(range.lowerBound)-\(range.upperBound)"
    }
}

extension String {
    /// Split into fixed-width lines, the way FASTA is written.
    func chunked(_ width: Int) -> [String] {
        guard width > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: width, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}
