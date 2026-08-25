//  SequenceInputView.swift
//  BOFFIN

import BoffinCore
import BoffinUI
import SwiftUI

struct SequenceInputView: View {
    @Bindable var store: SequenceStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    /// Ubiquitin, so the app is explorable without the user finding a sequence
    /// first. Same 76 residues as the 1UBQ fixture the tests use.
    private static let example =
        ">1UBQ ubiquitin\n"
        + "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"

    /// A kinase, so the Family tab has something to recognise.
    ///
    /// Ubiquitin is the right default (small, fast, and the honest "no family"
    /// answer), but it means the family features have nothing to show on a
    /// first run. P24941, human CDK2, is the protein every KLIFS number in this
    /// app was checked against.
    private static let kinaseExample =
        ">sp|P24941|CDK2_HUMAN cyclin-dependent kinase 2\n"
        + "MENFQKVEKIGEGTYGVVYKARNKLTGEVVALKKIRLDTETEGVPSTAIREISLLKELNH"
        + "PNIVKLLDVIHTENKLYLVFEFLHQDLKKFMDASALTGIPLPLIKSYLFQLLQGLAFCHS"
        + "HRVLHRDLKPQNLLINTEGAIKLADFGLARAFGVPVRTYTHEVVTLWYRAPEILLGCKYY"
        + "STAVDIWSLGCIFAEMVTRRALFPGDSEIDQLFRIFRTLGTPDEVVWPGVTSMPDYKPSF"
        + "PKWARQDFSKVVPPLDEDGRSLLSQMLHYDPNKRISAKAALAHPFFQDVTKPVPHLRL"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Paste a sequence, or a FASTA record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(Typography.sequence(size: 13))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                if let error = store.parseError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: Spacing.m) {
                    Button("Use the ubiquitin example") { text = Self.example }
                    Button("Use the CDK2 example") { text = Self.kinaseExample }
                }
                .font(.caption)
            }
            .padding(Spacing.m)
            .navigationTitle("Sequence")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Analyse") {
                        store.load(text: text)
                        if store.parseError == nil { dismiss() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
