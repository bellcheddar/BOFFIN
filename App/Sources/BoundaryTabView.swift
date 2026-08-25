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
                if let plan = store.tagPlan { tagSection(plan) }
                if let card = store.constructCard { cardSection(card) }
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

    /// Tag placement, and the protease check that matters more than it.
    private func tagSection(_ plan: TagPlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Tag and protease").font(.headline)
            HStack {
                Text("Place the tag at the \(plan.terminus.name) end")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.accent)
                Spacer()
            }
            ForEach(plan.rationale, id: \.self) { line in
                Text(line)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !plan.usableProteases.isEmpty {
                Text("Usable proteases").font(.caption.weight(.semibold))
                    .padding(.top, 2)
                ForEach(plan.usableProteases) { protease in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(protease.name).font(.caption.weight(.semibold))
                            Text(protease.recognition)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Brand.accent)
                            Spacer()
                            Text("scar \(protease.scar)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text(protease.note)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // The refusals are the point of this section, so they are not
            // tucked away: a protease that cuts inside the construct turns a
            // design error into what looks like proteolysis in the prep.
            if !plan.refusedProteases.isEmpty {
                Text("Refused, because the site occurs inside this construct")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(plan.refusedProteases, id: \.protease.id) { refusal in
                    HStack {
                        Text(refusal.protease.name).font(.caption)
                        Text(refusal.protease.recognition)
                            .font(.system(.caption2, design: .monospaced))
                        Spacer()
                        Text("at residue \(refusal.position + 1) of the construct")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The card, and the one control on this screen that leaves the app.
    private func cardSection(_ card: ConstructCard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Construct card").font(.headline)
                Spacer()
                ShareLink(item: card.text()) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .accessibilityIdentifier("boffin.share-construct-card")
            }
            Text(
                "Plain text: it survives being pasted into an order form, a notebook "
                    + "or a message, which a PDF does not."
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal) {
                Text(card.text())
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var caveat: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Not in this build", systemImage: "hammer")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(
                "Primer-ready DNA, which needs a codon usage table fetched and "
                    + "checksummed rather than transcribed. Disulfide pairing is not a "
                    + "constraint either: pairs cannot be read off a sequence, so a "
                    + "boundary can currently separate two cysteines that pair. That "
                    + "needs the structure viewer."
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
