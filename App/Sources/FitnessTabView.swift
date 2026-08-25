//  FitnessTabView.swift
//  BOFFIN
//
//  Per-position substitution tolerance: the delta-LLR heatmap, the sequence
//  logo, and a basket of mutations the user is collecting.
//
//  Every number here carries how it was produced. The two scoring modes give
//  matrices of identical shape that mean different things, and a reader cannot
//  tell them apart by looking, so the mode is stated next to the result rather
//  than buried in a settings screen.

import BoffinCharts
import BoffinCore
import BoffinML
import BoffinUI
import SwiftUI

struct FitnessTabView: View {
    @Bindable var store: SequenceStore
    @State private var selected: Mutation?
    @State private var pinned: Int?
    @State private var logoMode: SequenceLogoView.Mode = .informationContent

    var body: some View {
        NavigationStack {
            Group {
                if store.sequence == nil {
                    NoSequenceView(
                        title: "No sequence", systemImage: "square.grid.3x3",
                        promise: "Every point mutation, scored by how much the model "
                            + "dislikes it, appears here.",
                        store: store)
                } else {
                    content
                }
            }
            .navigationTitle("Fitness")
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                controls
                if let matrix = store.llr {
                    heatmap(matrix)
                    logo(matrix)
                    if !store.mutations.isEmpty { basket }
                }
            }
            .padding(Spacing.m)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            switch store.scanState {
            case .idle, .cancelled, .failed, .notBundled:
                Text("Score every substitution at every position.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: Spacing.s) {
                    Button("Fast preview") { store.scan(mode: .wildTypeMarginal) }
                        .buttonStyle(.bordered)
                    Button("Masked marginal") { store.scan(mode: .maskedMarginal) }
                        .buttonStyle(.borderedProminent)
                }
                Text(
                    "The fast preview is one model pass over the whole sequence. "
                        + "Masked marginal runs one pass per position: slower, and the "
                        + "model does not see the residue it is scoring."
                )
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                if store.predictions != nil {
                    Toggle("Skip predicted disordered positions", isOn: $store.maskDisordered)
                        .font(.caption)
                }
                // Two cases, not one string compared against a constant to
                // work out which of two things happened. The comparison was
                // standing in for a type distinction the enum now makes.
                if case .notBundled = store.scanState {
                    Label(SequenceStore.modelsMissingMessage, systemImage: "cube.box")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("boffin.models-missing")
                }
                if case .failed(let failure) = store.scanState {
                    FailureView(failure) { store.scan(mode: .maskedMarginal) }
                        .accessibilityIdentifier("boffin.scan-failed")
                }
                if case .cancelled = store.scanState {
                    Text("Scan cancelled.").font(.caption2).foregroundStyle(.secondary)
                }

            case .running(let fraction):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ProgressView(value: fraction) {
                        Text("Scoring \(Int(fraction * 100))%")
                            .font(.caption)
                    }
                    Button("Cancel", role: .cancel) { store.cancelScan() }
                        .font(.caption)
                }

            case .ready:
                HStack {
                    if let mode = store.llrMode {
                        VStack(alignment: .leading, spacing: 1) {
                            Label(mode.displayName, systemImage: "checkmark.seal")
                                .font(.caption.weight(.semibold))
                            Text(mode.provenance)
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if let matrix = store.llr {
                        ShareLink(
                            item: matrix.commaSeparatedValues(),
                            preview: SharePreview("Delta LLR matrix")
                        ) {
                            Label("CSV", systemImage: "square.and.arrow.up")
                        }
                        .font(.caption)
                    }
                }
                if store.llrMode == .wildTypeMarginal {
                    Button("Run the accurate scan") { store.scan(mode: .maskedMarginal) }
                        .font(.caption)
                }
            }
        }
    }

    private func heatmap(_ matrix: LLRMatrix) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Substitution matrix").font(.headline)
            Text("Blue is tolerated, red is deleterious. Tap a cell to collect it.")
                .font(.caption2).foregroundStyle(.secondary)
            LLRHeatmapView(matrix: matrix, selected: $selected, style: .boffin)
            if let selected {
                HStack(spacing: Spacing.s) {
                    Text(selected.label)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    Text(String(format: "%.2f", selected.score))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(selected.score < 0 ? .red : .blue)
                    Spacer()
                    Button(store.mutations.contains(selected) ? "Remove" : "Add") {
                        store.toggle(selected)
                    }
                    .font(.caption)
                }
                .padding(Spacing.s)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func logo(_ matrix: LLRMatrix) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Sequence logo").font(.headline)
                Spacer()
                Picker("Mode", selection: $logoMode) {
                    ForEach(SequenceLogoView.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            Text("Height is \(logoMode.unit).")
                .font(.caption2).foregroundStyle(.secondary)
            SequenceLogoView(
                matrix: matrix, mode: logoMode, pinned: $pinned, style: .boffin)
        }
    }

    private var basket: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Mutation basket").font(.headline)
            ForEach(store.mutations) { mutation in
                HStack {
                    Text(mutation.label)
                        .font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    Text(String(format: "%.2f", mutation.score))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(mutation.score < 0 ? .red : .blue)
                    Button {
                        store.toggle(mutation)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            ShareLink(
                item: store.mutations.map(\.label).joined(separator: "\n"),
                preview: SharePreview("Mutations")
            ) {
                Label("Share list", systemImage: "square.and.arrow.up").font(.caption)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
