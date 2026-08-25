//  OrderTabView.swift
//  BOFFIN
//
//  Phase 1's deliverable: paste a sequence, see it on the ruler with analytical
//  tracks, select a span and read its properties.
//
//  Phase 3 adds the model-derived tracks (disorder, secondary structure, TM
//  spans) to this same ruler rather than to a new view. That is invariant 2
//  working: the tab is a filter over one ruler, so a new track is a new array,
//  not a new screen.

import BoffinCharts
import BoffinCore
import BoffinUI
import SwiftUI

struct OrderTabView: View {
    @Bindable var store: SequenceStore
    @State private var isShowingInput = false

    var body: some View {
        NavigationStack {
            Group {
                if let sequence = store.sequence {
                    content(for: sequence)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Order")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Acknowledgements")
                    .accessibilityIdentifier("boffin.acknowledgements-link")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sequence", systemImage: "square.and.pencil") {
                        isShowingInput = true
                    }
                }
            }
            .sheet(isPresented: $isShowingInput) {
                SequenceInputView(store: store)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No sequence", systemImage: "text.alignleft")
        } description: {
            Text("Paste a sequence or FASTA record to see its properties and tracks.")
        } actions: {
            Button("Paste a sequence") { isShowingInput = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func content(for sequence: ProteinSequence) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header(for: sequence)

                if !store.diagnostics.isEmpty {
                    DiagnosticsView(diagnostics: store.diagnostics)
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Ruler")
                        .font(.headline)
                    Text("Pinch to zoom, drag to select a span.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TrackRulerView(
                        sequence: sequence,
                        tracks: store.allTracks,
                        selection: $store.selection,
                        style: .boffin)
                    trackLegend
                    modelStatus
                }

                if let selection = store.selection, let properties = store.selectionProperties {
                    PropertiesView(
                        title:
                            "Selection: \(selection.lowerBound + 1) to \(selection.upperBound + 1)",
                        properties: properties)
                }

                if let properties = store.properties {
                    PropertiesView(title: "Whole sequence", properties: properties)
                }

                settings
            }
            .padding(Spacing.m)
        }
    }

    private func header(for sequence: ProteinSequence) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(sequence.name)
                .font(.headline)
            Text("\(sequence.count) residues \u{00B7} \(provenance(of: sequence.source))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func provenance(of source: SequenceSource) -> String {
        switch source {
        case .pasted: "pasted"
        case .fasta(let fileName): fileName
        case .uniProt(let accession): "UniProt \(accession)"
        case .pdbSeqRes(let entry, let chain): "PDB \(entry) chain \(chain)"
        case .fixture(let name): "fixture \(name)"
        }
    }

    private var trackLegend: some View {
        HStack(spacing: Spacing.m) {
            ForEach(store.allTracks, id: \.id.rawValue) { track in
                Text(track.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The model's state, stated plainly.
    ///
    /// The disorder head is materially better on proteins with relatives in
    /// the PDB than on novel folds (MCC 0.63 on TS115, 0.50 on CASP12, against
    /// a no-language-model floor of 0.57). Averaging those into one number
    /// would hide exactly the case where the answer is least trustworthy, so
    /// the caveat travels with the track.
    @ViewBuilder
    private var modelStatus: some View {
        switch store.modelState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Running the model ...").font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let passes):
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    passes == 1
                        ? "Secondary structure and disorder predicted from one model pass."
                        : "Predicted from \(passes) tiled model passes.",
                    systemImage: "checkmark.seal"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Corrected 2026-08-25, twice in one day, and the second
                // correction was of the first.
                //
                // The wording briefly claimed this head "measures below what
                // the same head achieves with no language model at all". That
                // was false. It compared against NetSurfP's published one-hot
                // baseline, which is NetSurfP's architecture, not this one.
                // Training THIS head on one-hot amino acids, same seed, same
                // schedule, same chains, gives 0.380 on CB513 against 0.426
                // with the embeddings: the language model is contributing
                // +0.046 there and +0.106 on TS115.
                //
                // The real gap is to NetSurfP's model and training budget, not
                // to its input representation, and that is a different
                // sentence with a different meaning for a reader deciding
                // whether to trust the track.
                Text(
                    "Disorder is the weakest of these tracks and the one to treat as a "
                        + "hint rather than a call. It is well short of the best published "
                        + "predictors, which are larger models trained end to end. "
                        + "Research use only."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .notBundled:
            // Not a failure: a clean checkout has no 67 MB backbone in it, and
            // every analytical track on this ruler still works without one.
            Label(SequenceStore.modelsMissingMessage, systemImage: "cube.box")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("boffin.models-missing")
        case .failed(let failure):
            FailureView(failure)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Settings")
                .font(.headline)

            Picker("pKa scale", selection: $store.pKaScale) {
                ForEach(PKaScale.allCases) { scale in
                    Text(scale.displayName).tag(scale)
                }
            }
            .pickerStyle(.segmented)

            Text(store.pKaScale.provenance)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Stepper(
                "Hydropathy window: \(store.hydropathyWindow)",
                value: $store.hydropathyWindow, in: 3...25, step: 2)
            Text(
                "Kyte and Doolittle used 7 for general hydropathy and 19 for membrane spans. "
                    + "The window changes what the plot appears to say, so it is shown rather "
                    + "than fixed."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Non-fatal parse observations, shown rather than swallowed.
struct DiagnosticsView: View {
    let diagnostics: [FASTADiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Input notes", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            ForEach(diagnostics) { diagnostic in
                Text(diagnostic.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
