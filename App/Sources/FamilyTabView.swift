//  FamilyTabView.swift
//  BOFFIN
//
//  Family assignment and the canonical motifs that make the other tabs
//  interpretable: a delta-LLR at the DFG aspartate means something a
//  delta-LLR at an arbitrary surface residue does not.
//
//  Motif annotation from published sequence definitions, canonical numbering,
//  the Pfam classifier, and homolog search over the PDB with SIFTS mapping to
//  author residue numbers.
//
//  Two numbers on this screen are easy to confuse and are deliberately never
//  shown without each other: the EMBEDDING SIMILARITY is a cosine between
//  pooled representations, and the IDENTITY is from an actual alignment. They
//  disagree exactly where the index earns its keep, on remote homologues that
//  share a fold at low identity.

import BoffinCore
import BoffinData
import BoffinML
import BoffinUI
import SwiftUI

struct FamilyTabView: View {
    @Bindable var store: SequenceStore

    var body: some View {
        NavigationStack {
            Group {
                if store.sequence == nil {
                    NoSequenceView(
                        title: "No sequence",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        promise: "Family, motifs, canonical numbering and the closest "
                            + "relatives in the PDB appear here.",
                        store: store)
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
                if let call = store.familyCall { classification(call) }
                if store.motifs.isEmpty {
                    noFamilyRecognised
                } else {
                    ForEach(MotifFamily.allCases, id: \.rawValue) { family in
                        if let found = store.motifs[family], !found.isEmpty {
                            familySection(family, found)
                        }
                    }
                }
                if let numbering = store.numbering, let scheme = store.numberingScheme {
                    numberingSection(numbering, scheme: scheme)
                }
                homologSection
                if !store.precedent.isEmpty { precedentSection }
            }
            .padding(Spacing.m)
        }
    }

    /// The classifier's ranked call, with its confidence presented honestly.
    private func classification(_ call: FamilyClassification) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Pfam classification").font(.headline)

            // The caveat is always shown, not only when confidence is low.
            // A closed-set classifier reports the nearest of its trained
            // families whatever it is given, so "confident" and "correct" are
            // different claims and the difference has to be on screen.
            Label(
                call.caveat,
                systemImage: call.isInDistribution && call.isConfident
                    ? "info.circle" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(
                call.isInDistribution && call.isConfident ? Color.secondary : Color.orange
            )
            .fixedSize(horizontal: false, vertical: true)

            ForEach(call.ranked) { entry in
                HStack {
                    Text(entry.accession)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(entry.id == call.top?.id ? Brand.accent : .secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", entry.confidence * 100))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                String(
                    format:
                        "Confidence is calibrated: the model is right %.0f%% of the time "
                        + "on held-out data, and its calibration error is under 1%%, so a "
                        + "reported percentage means roughly what it says. "
                        + "Trained on %d Pfam families.",
                    call.top1Accuracy * 100, call.ranked.isEmpty ? 0 : 100)
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
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

    private func numberingSection(_ result: NumberingResult, scheme: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(scheme) numbering").font(.headline)
            // The confidence travels with the number, always. A residue number
            // gets copied out of an app; a caveat in a footnote does not.
            Text(
                "Mapped from \(result.reference) at "
                    + "\(Int(result.identity * 100))% identity over the reference. "
                    + "\(result.numbers.count) residues numbered."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // The landmarks by name. A ruler cell reading "GK.45" is correct
            // and useless to anyone who does not already know that 45 is the
            // gatekeeper.
            if !store.pocketAnchors.isEmpty {
                ForEach(store.pocketAnchors) { anchor in
                    HStack {
                        Text(anchor.name).font(.caption.weight(.semibold))
                        Text(anchor.label)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(anchor.description)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Brand.accent)
                    }
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Homologs

    @ViewBuilder
    private var homologSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Homologs in the PDB").font(.headline)

            switch store.homologState {
            case .idle:
                EmptyView()
            case .searching:
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Searching").font(.caption).foregroundStyle(.secondary)
                }
            case .notDownloaded:
                // Named the file and nothing else. The catalogue carries what
                // each asset enables and what it costs, in the user's terms
                // and for exactly this message, and neither reached the screen:
                // a user reading that an index is missing has no way to judge
                // whether to care.
                Label(
                    "\(BoffinAsset.homologVectors.enables) needs a "
                        + "\(BoffinAsset.homologSearch.approximateSize) download "
                        + "that has not been made.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let failure):
                FailureView(failure, icon: "exclamationmark.triangle")
            case .ready(let count) where count == 0:
                Text(
                    "Nothing in the index is close to this sequence. The index holds one "
                        + "representative chain per UniProt accession in the PDB, so this "
                        + "means no solved structure resembles it, not that none exists."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .ready:
                ForEach(store.homologs, id: \.hit.id) { homolog in
                    homologRow(homolog)
                }
                Text(
                    "Similarity is a cosine between pooled embeddings and is NOT a "
                        + "percentage identity: two proteins with the same fold and 15% "
                        + "identity can score highly, which is the point of searching this "
                        + "way. Identity and coverage come from an alignment against the "
                        + "entry's SEQRES."
                )
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func homologRow(_ homolog: HomologAlignment) -> some View {
        let hit = homolog.hit
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(hit.pdb)_\(hit.chain)")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Brand.accent)
                Text(hit.accession)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let resolution = hit.resolution {
                    Text(String(format: "%.2f A", resolution))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(hit.title)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.s) {
                measure("similarity", String(format: "%.3f", hit.similarity))
                measure("identity", String(format: "%.0f%%", homolog.identity * 100))
                measure("coverage", String(format: "%.0f%%", homolog.coverage * 100))
                measure("entries", String(hit.structureCount))
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func measure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.caption, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Crystallisation precedent

    /// What people actually got to order, for the closest homolog.
    ///
    /// The disordered count is the interesting column: it is the part of the
    /// construct that was present in the crystal and invisible in the map, which
    /// is the evidence the Boundary tab needs and the opposite of what a
    /// sequence-only prediction can tell you.
    private var precedentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Deposited constructs").font(.headline)
            if let best = store.homologs.first {
                Text("Observed spans for \(best.hit.accession), UniProt numbering.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.precedent.prefix(8)) { construct in
                HStack {
                    Text(construct.pdb)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.accent)
                    Text("\(construct.first) to \(construct.last)")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("\(construct.observedCount) observed")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if construct.disorderedCount > 0 {
                        Text("\(construct.disorderedCount) disordered")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
