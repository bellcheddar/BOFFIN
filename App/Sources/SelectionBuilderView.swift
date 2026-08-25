//  SelectionBuilderView.swift
//  BOFFIN
//
//  Composing a selection by tapping, so the language is optional.
//
//  `byres (polymer within 5 of organic)` is a fine thing to type on a keyboard
//  and a miserable thing to type on a phone, where the brackets and the
//  underscore live two modifier taps away. That is a real barrier to the
//  feature rather than a cosmetic one: a selection nobody can be bothered to
//  type is a selection nobody makes.
//
//  The important decision: **the builder writes the language, it does not
//  replace it.** Every tap edits the same expression string the user could have
//  typed, that string is shown, it stays editable, and it is evaluated by the
//  same parser everything else uses. Two consequences, both deliberate:
//
//  - The builder cannot express anything the language cannot, so there is no
//    second selection system to disagree with the first. A visual builder with
//    its own model is how two selection systems end up producing different
//    answers for what the user believes is one query.
//  - The user learns the syntax by watching it assemble, which matters because
//    the expression is what travels in a `.pml` file to a desktop.
//
//  And the count is live. A selection is a claim about a structure, and the
//  only way to know whether the claim is the one you meant is to see how many
//  atoms it caught before you act on it. An over-broad selection makes a figure
//  that is wrong in a way nobody can see.

import BoffinStructure
import BoffinUI
import SwiftUI

struct SelectionBuilderView: View {
    let atoms: AtomStore
    @Binding var expression: String
    @Environment(\.dismiss) private var dismiss

    /// What the current expression matches, or why it does not parse.
    private var outcome: Outcome {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        do {
            let parsed = try SelectionParser.parse(trimmed)
            let indices = SelectionEvaluator.evaluate(parsed, in: atoms).indices
            var residues = Set<String>()
            for index in indices {
                residues.insert("\(atoms.chainID[index])/\(atoms.authorNumber[index])")
            }
            return .matched(atoms: indices.count, residues: residues.count)
        } catch let error as SelectionError {
            return .failed(error.message)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private enum Outcome {
        case empty
        case matched(atoms: Int, residues: Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Expression") {
                    TextEditor(text: $expression)
                        .sequenceFont(size: 13)
                        .frame(minHeight: 60)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("boffin.selection.expression")
                    outcomeLabel
                }

                Section("What") {
                    // Categories first: they are the most common starting
                    // point and the least typeable.
                    flow(Selection.Category.allCases.map(\.rawValue)) { token in
                        append(token)
                    }
                }

                if atoms.chains.count > 1 {
                    Section("Chain") {
                        flow(atoms.chains) { chain in append("chain \(chain)") }
                    }
                }

                Section("Refine") {
                    Button("Within 5 Å of the current selection") {
                        wrap { "polymer within 5 of (\($0))" }
                    }
                    .accessibilityIdentifier("boffin.selection.within")
                    Button("Whole residues (byres)") {
                        wrap { "byres (\($0))" }
                    }
                    .accessibilityIdentifier("boffin.selection.byres")
                    Button("Invert (not)") {
                        wrap { "not (\($0))" }
                    }
                    Button("Clear", role: .destructive) { expression = "" }
                }

                Section {
                    Text(
                        "Every button here writes the same expression you could type, "
                            + "so it travels into a .pml file and opens on a desktop."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var outcomeLabel: some View {
        switch outcome {
        case .empty:
            Text("Nothing selected yet.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("boffin.selection.count")
        case .matched(let atomCount, let residueCount):
            // Zero is called out rather than shown as a number among numbers.
            // An expression that parses and matches nothing is the failure that
            // looks most like success, and it is the one that puts an empty
            // overlay or a blank figure in front of someone.
            if atomCount == 0 {
                Label(
                    "Parses, but matches nothing in this structure.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(ScientificPalette.warning)
                .accessibilityIdentifier("boffin.selection.count")
            } else {
                Text(
                    "\(atomCount.formatted()) atoms in \(residueCount.formatted()) residues"
                )
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("boffin.selection.count")
            }
        case .failed(let message):
            // The parser names the keyword it could not read. Passing that
            // through verbatim is the difference between fixing a typo and
            // guessing at a syntax.
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(ScientificPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("boffin.selection.count")
        }
    }

    /// Buttons that wrap rather than overflow.
    ///
    /// A row of category chips clips its own labels at the larger accessibility
    /// text sizes, and a truncated chip is a control whose purpose has been
    /// deleted.
    @ViewBuilder
    private func flow(_ tokens: [String], action: @escaping (String) -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) { buttons(tokens, action: action) }
            VStack(alignment: .leading, spacing: Spacing.s) { buttons(tokens, action: action) }
        }
    }

    @ViewBuilder
    private func buttons(_ tokens: [String], action: @escaping (String) -> Void) -> some View {
        ForEach(tokens, id: \.self) { token in
            Button(token) { action(token) }
                .buttonStyle(.bordered)
                .font(.caption)
                .accessibilityIdentifier("boffin.selection.token.\(token)")
        }
    }

    /// Add a term, joined with `and`.
    ///
    /// `and` rather than `or` because tapping two things reads as narrowing:
    /// someone who taps "organic" and then "chain A" means the ligand in chain
    /// A, not everything organic plus everything in chain A. The expression is
    /// visible and editable, so the less common reading is one character away.
    private func append(_ token: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        expression = trimmed.isEmpty ? token : "\(trimmed) and \(token)"
    }

    /// Wrap the whole expression in a modifier.
    private func wrap(_ transform: (String) -> String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        expression = transform(trimmed)
    }
}
