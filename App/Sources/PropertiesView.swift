//  PropertiesView.swift
//  BOFFIN
//
//  The analytical panel. Every number states what produced it: a pI without its
//  pKa scale, or an extinction coefficient without its cysteine assumption, is
//  a number the user cannot check.

import BoffinCore
import BoffinUI
import SwiftUI

struct PropertiesView: View {
    let title: String
    let properties: SequenceProperties

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.headline)

            if properties.nonCanonicalCount > 0 {
                Label(
                    """
                    \(properties.nonCanonicalCount) non-canonical \
                    \(properties.nonCanonicalCount == 1 ? "residue is" : "residues are") \
                    excluded from these figures.
                    """,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                row("Residues", "\(properties.residueCount)")
                row("Molecular weight", String(format: "%.2f Da", properties.molecularWeight))
                row(
                    "Isoelectric point",
                    String(format: "%.2f", properties.isoelectricPoint),
                    note: properties.pKaScale.displayName)
                row(
                    "\u{03B5}\u{2082}\u{2088}\u{2080} reduced",
                    String(
                        format: "%.0f M\u{207B}\u{00B9} cm\u{207B}\u{00B9}",
                        properties.extinctionCoefficientReduced),
                    note: "all cysteines reduced")
                if properties.extinctionCoefficientCystine
                    != properties.extinctionCoefficientReduced
                {
                    row(
                        "\u{03B5}\u{2082}\u{2088}\u{2080} cystine",
                        String(
                            format: "%.0f M\u{207B}\u{00B9} cm\u{207B}\u{00B9}",
                            properties.extinctionCoefficientCystine),
                        note: "all cysteines paired")
                }
                if let absorbance = properties.absorbance01PercentReduced {
                    row("A\u{2082}\u{2088}\u{2080} at 1 g/L", String(format: "%.3f", absorbance))
                }
                row("GRAVY", String(format: "%.3f", properties.gravy))
                row(
                    "Instability index",
                    String(format: "%.2f", properties.instabilityIndex),
                    note: properties.isPredictedStable
                        ? "below 40: predicted stable"
                        : "above 40: predicted unstable")
            }

            if properties.extinctionCoefficientReduced == 0 && properties.residueCount > 0 {
                Text(
                    "No tryptophan or tyrosine, so this protein cannot be quantified by "
                        + "absorbance at 280 nm."
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: String, note: String? = nil) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.subheadline, design: .monospaced))
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
