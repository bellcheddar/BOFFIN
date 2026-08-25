//  AcknowledgementsView.swift
//  BOFFIN
//
//  Phase 11: the attributions screen.
//
//  Every source BOFFIN uses is credited here whether or not its licence demands
//  it, which is the position `Docs/ATTRIBUTIONS.md` records. Several of these
//  datasets state no terms at all; attribution is not what they ask for, it is
//  what they deserve.
//
//  The text lives in the binary rather than in a bundled Markdown file. A
//  screen that silently shows nothing because a resource did not copy is worse
//  than no screen, and this one cannot fail that way.

import BoffinCore
import BoffinUI
import SwiftUI

struct AcknowledgementsView: View {

    struct Credit: Identifiable, Hashable {
        let name: String
        let terms: String
        let use: String
        let citation: String
        var id: String { name }
    }

    /// What BOFFIN is built on.
    ///
    /// The `terms` column is the honest one: several of these say "none
    /// stated", and writing that is the point. Rounding an unstated licence up
    /// to a permissive one on an acknowledgements screen would be misleading
    /// exactly where a reader is looking for the truth.
    static let credits: [Credit] = [
        Credit(
            name: "ESM-2",
            terms: "MIT",
            use: "The language model every analysis reads from, running on the "
                + "Neural Engine.",
            citation: "Lin et al., Science 379:1123 (2023)"),
        Credit(
            name: "Mol*",
            terms: "MIT",
            use: "The structure viewer, vendored in full so the app works offline.",
            citation: "Sehnal et al., Nucleic Acids Res 49:W431 (2021)"),
        Credit(
            name: "RCSB PDB",
            terms: "CC0 1.0",
            use: "Structures, sequences, the codon usage table and the labels the "
                + "disorder and secondary structure heads can be trained on.",
            citation: "Berman et al., Nucleic Acids Res 28:235 (2000)"),
        Credit(
            name: "UniProt",
            terms: "CC BY 4.0",
            use: "Sequences, Pfam annotations, and the transmembrane and signal "
                + "peptide features the topology head is trained on.",
            citation: "The UniProt Consortium, Nucleic Acids Res 51:D523 (2023)"),
        Credit(
            name: "GPCRdb",
            terms: "CC BY 4.0",
            use: "Generic numbering for class A GPCRs.",
            citation: "Kooistra et al., Nucleic Acids Res 49:D335 (2021)"),
        Credit(
            name: "KLIFS",
            terms: "Stated open for academia and industry, no named licence",
            use: "The 85-residue kinase pocket numbering.",
            citation: "Kanev et al., Nucleic Acids Res 49:D562 (2021)"),
        Credit(
            name: "SIFTS",
            terms: "None stated",
            use: "Residue-level correspondence between UniProt and PDB numbering, "
                + "and the deposited constructs the Boundary tab plans against.",
            citation: "Dana et al., Nucleic Acids Res 47:D482 (2019)"),
        Credit(
            name: "NetSurfP datasets (CB513, TS115, CASP12)",
            terms: "None stated",
            use: "Training and evaluation for the secondary structure and disorder "
                + "heads.",
            citation: "Klausen et al., Proteins 87:520 (2019)"),
        Credit(
            name: "DSSP",
            terms: "Method, implemented here from the paper",
            use: "Secondary structure assigned from coordinates. No DSSP source "
                + "was read.",
            citation: "Kabsch and Sander, Biopolymers 22:2577 (1983)"),
        Credit(
            name: "PLIP",
            terms: "GPL v2, never linked or ported",
            use: "The published geometric criteria the interaction profiler "
                + "implements independently.",
            citation: "Adasme et al., Nucleic Acids Res 49:W530 (2021)"),
    ]

    var body: some View {
        List {
            Section {
                Text(
                    "BOFFIN runs entirely on your device. Nothing you load is sent "
                        + "anywhere, and the only network request the app can make is "
                        + "a structure you ask for by name."
                )
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Built on") {
                ForEach(Self.credits) { credit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(credit.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(credit.terms)
                                .font(.caption2)
                                .foregroundStyle(
                                    credit.terms.lowercased().contains("none stated")
                                        ? Color.orange : Color.secondary)
                        }
                        Text(credit.use)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(credit.citation)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Terms") {
                Text(
                    "Several sources above state no licence. BOFFIN uses them for "
                        + "non-commercial research, which is the narrowest reading of "
                        + "an unstated position rather than a permission that was "
                        + "given. They are credited here regardless of whether a "
                        + "licence asks for it."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(
                    "Research use only. Nothing in BOFFIN is intended for clinical, "
                        + "diagnostic or therapeutic use."
                )
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("boffin.research-use-only")
            }
        }
        .navigationTitle("Acknowledgements")
        .accessibilityIdentifier("boffin.acknowledgements")
    }
}
