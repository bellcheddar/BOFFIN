//  BoundaryTabView.swift
//  BOFFIN
//
//  Phase 6: construct design.
//
//  The tab shows what is being ENFORCED as prominently as what is being
//  proposed. A ranked list of boundaries with no visible constraints reads as an
//  opinion; the same list next to "these five regions may not be cut" reads as a
//  derivation, and a user can tell at a glance whether the solver knew about the
//  thing they care about.

import BoffinCore
import BoffinUI
import SwiftUI

struct BoundaryTabView: View {
    @Bindable var store: SequenceStore

    var body: some View {
        NavigationStack {
            Group {
                if store.sequence == nil {
                    ContentUnavailableView(
                        "No sequence", systemImage: "scissors",
                        description: Text("Load a sequence in the Order tab first."))
                } else {
                    content
                }
            }
            .navigationTitle("Boundary")
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                switch store.constructs {
                case .declined(let reason):
                    declined(reason)
                case .proposals(let proposals):
                    proposalList(proposals)
                }
                constraintList
                caveat
            }
            .padding(Spacing.m)
        }
    }

    /// A refusal is a finding, so it gets the same visual weight as an answer
    /// rather than being tucked into an empty state.
    private func declined(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("No construct proposed", systemImage: "hand.raised")
                .font(.headline)
            Text(reason)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func proposalList(_ proposals: [ConstructProposal]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Proposed constructs").font(.headline)
            ForEach(Array(proposals.enumerated()), id: \.element.id) { index, proposal in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(proposal.description)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(index == 0 ? Brand.accent : .primary)
                        Text("\(proposal.length) residues")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if proposal.precedentCount > 0 {
                            Label(
                                "\(proposal.precedentCount)", systemImage: "checkmark.seal"
                            )
                            .font(.caption2).foregroundStyle(Brand.accent)
                        }
                    }
                    ForEach(proposal.rationale, id: \.self) { line in
                        Text(line)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var constraintList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Regions that may not be cut").font(.headline)
            if store.constructConstraints.isEmpty {
                Text(
                    "Nothing is being enforced. No motifs were recognised and no "
                        + "transmembrane spans were predicted, so every boundary above "
                        + "rests on the disorder track alone."
                )
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.constructConstraints, id: \.self) { constraint in
                    HStack {
                        Text(constraint.label)
                            .font(.caption)
                        Spacer()
                        Text(
                            "\(constraint.range.lowerBound + 1) to "
                                + "\(constraint.range.upperBound + 1)"
                        )
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        Text(constraint.kind == .signalPeptide ? "removable" : "kept")
                            .font(.system(size: 9))
                            .foregroundStyle(
                                constraint.kind == .signalPeptide ? .secondary : Brand.accent)
                    }
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var caveat: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Not in this build", systemImage: "hammer")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(
                "Tag and linker planning, and construct card export with primer-ready "
                    + "DNA. Disulfide pairing is not yet a constraint either, so a "
                    + "boundary can currently separate two cysteines that pair."
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
