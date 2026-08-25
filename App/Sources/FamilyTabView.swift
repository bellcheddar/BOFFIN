//  FamilyTabView.swift
//  BOFFIN
//
//  Family assignment and the canonical motifs that make the other tabs
//  interpretable: a delta-LLR at the DFG aspartate means something a
//  delta-LLR at an arbitrary surface residue does not.
//
//  What is here is motif annotation from published sequence definitions,
//  validated against proteins whose residue numbers are in textbooks. What is
//  NOT here yet is the embedding classifier and homolog search, and the tab
//  says so rather than implying the absence is a negative result.

import BoffinCore
import BoffinUI
import SwiftUI

struct FamilyTabView: View {
    @Bindable var store: SequenceStore

    var body: some View {
        NavigationStack {
            Group {
                if store.sequence == nil {
                    ContentUnavailableView(
                        "No sequence", systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Load a sequence in the Order tab first."))
                } else {
                    content
                }
            }
            .navigationTitle("Family")
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if store.motifs.isEmpty {
                    noFamilyRecognised
                } else {
                    ForEach(MotifFamily.allCases, id: \.rawValue) { family in
                        if let found = store.motifs[family], !found.isEmpty {
                            familySection(family, found)
                        }
                    }
                }
                pending
            }
            .padding(Spacing.m)
        }
    }

    private var noFamilyRecognised: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("No family motifs recognised", systemImage: "questionmark.circle")
                .font(.headline)
            Text(
                "BOFFIN annotates protein kinases and class A GPCRs by their canonical "
                    + "sequence motifs. Finding none is not a statement that the protein "
                    + "belongs to neither: it means the anchors this build looks for were "
                    + "not present in the expected order."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func familySection(_ family: MotifFamily, _ found: [Motif]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(displayName(family)).font(.headline)
            ForEach(found) { motif in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(motif.name)
                            .font(.subheadline.weight(.semibold))
                        Text(motif.matched)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Brand.accent)
                        Spacer()
                        // One-based, as every paper quotes it.
                        Text(residueLabel(motif))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(motif.role)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func residueLabel(_ motif: Motif) -> String {
        let start = motif.range.lowerBound + 1
        let end = motif.range.upperBound + 1
        return start == end ? "\(start)" : "\(start) to \(end)"
    }

    private func displayName(_ family: MotifFamily) -> String {
        switch family {
        case .proteinKinase: "Protein kinase"
        case .classAGPCR: "Class A GPCR"
        }
    }

    /// State plainly what this tab does not do yet.
    private var pending: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Not in this build", systemImage: "hammer")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(
                "Pfam classification from the pooled embedding, KLIFS and GPCRdb residue "
                    + "numbering, SIFTS mapping to PDB author numbers, and homolog search "
                    + "over the bundled embedding index. The numbering tables are fetched "
                    + "and bundled; mapping a pasted sequence onto them needs alignment, "
                    + "which is not written yet."
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
