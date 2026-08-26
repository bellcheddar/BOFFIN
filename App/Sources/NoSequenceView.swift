//  NoSequenceView.swift
//  BOFFIN
//
//  The empty state for the four tabs that need a sequence before they can show
//  anything.
//
//  All four said "Load a sequence in the Order tab first" and offered no way to
//  do it. That is a dead end wearing the clothes of an explanation: it names the
//  fix, sends the user somewhere else to perform it, and takes no action itself.
//  This one carries the same input sheet the Order tab uses, plus the two
//  bundled examples, so the tab that told you what was missing is also the tab
//  that supplies it.
//
//  Each tab still says what IT will do once there is a sequence, because
//  "nothing here yet" is not the same information as "this is where the
//  mutation map appears".

import BoffinUI
import SwiftUI

struct NoSequenceView: View {
    let title: String
    let systemImage: String
    /// What this particular tab will show, in its own words.
    let promise: String

    @Bindable var store: SequenceStore
    @State private var isShowingInput = false

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(promise)
        } actions: {
            VStack(spacing: Spacing.s) {
                Button("Paste a sequence") { isShowingInput = true }
                    .buttonStyle(.borderedProminent)
                    .minimumTouchTarget()
                    .accessibilityIdentifier("boffin.empty.paste")

                // Deliberately a flow layout rather than an HStack: at the
                // larger accessibility text sizes two buttons side by side
                // clip their own labels, and a truncated button is a button
                // whose purpose has been deleted.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.m) { exampleButtons }
                    VStack(spacing: Spacing.s) { exampleButtons }
                }
                .font(.callout)
            }
        }
        .sheet(isPresented: $isShowingInput) {
            SequenceInputView(store: store)
        }
    }

    @ViewBuilder
    private var exampleButtons: some View {
        ForEach(ExampleSequences.all) { example in
            Button("Load \(example.title)") { store.load(text: example.fasta) }
                .minimumTouchTarget()
                .accessibilityIdentifier("boffin.empty.example.\(example.id)")
        }
    }
}
