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

                Button("Use the ubiquitin example") { text = Self.example }
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
