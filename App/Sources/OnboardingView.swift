//  OnboardingView.swift
//  BOFFIN
//
//  What a first-time user is told, once.
//
//  Three things, in this order, because they are what someone who has just
//  installed this actually needs to know:
//
//  1. Nothing leaves the device. This is the claim that decides whether an
//     unpublished sequence gets pasted in at all, so it goes first rather than
//     into a privacy policy nobody opens.
//  2. One pass, four answers. Not a boast about the architecture: it is why the
//     four tabs are not four separate waits.
//  3. What it gets wrong. An onboarding screen that only sells is how a user
//     ends up trusting the closed-set classifier the first time it is confidently
//     wrong. Saying it here costs one paragraph and buys the app's credibility
//     for the rest of its life.
//
//  It ends on an action rather than a dismiss, because the fastest way to
//  understand a ruler with six tracks on it is to be looking at one.

import BoffinUI
import SwiftUI

struct OnboardingView: View {
    @Bindable var store: SequenceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header

                    point(
                        icon: "iphone.gen3",
                        title: "Nothing leaves this device",
                        detail: "There is no server, no account and no telemetry. "
                            + "The model runs on the Neural Engine in your hand, so a "
                            + "sequence you have not published yet stays unpublished. "
                            + "Structures are fetched from the PDB only when you ask for one.")

                    point(
                        icon: "arrow.triangle.branch",
                        title: "One pass, four answers",
                        detail: "The protein language model runs once. Disorder and "
                            + "structure, mutation tolerance, family, and the search for "
                            + "relatives are four read-outs of that same pass rather than "
                            + "four separate waits.")

                    point(
                        icon: "exclamationmark.triangle",
                        title: "It will tell you when it is guessing",
                        detail: "The family classifier knows 100 families and must answer "
                            + "with one of them, so it can be confidently wrong about a "
                            + "protein outside that set. Disorder is weakest on folds with "
                            + "no close relative in the PDB. Both say so on screen, and a "
                            + "predicted structure is always labelled as one.")

                    Text("Research use only. No clinical, diagnostic or therapeutic claims.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Divider()

                    start
                }
                .padding(Spacing.m)
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("boffin.onboarding.done")
                }
            }
        }
        .accessibilityIdentifier("boffin.onboarding")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("BOFFIN")
                .font(.largeTitle.bold())
            Text("Boundary, Order, Fitness and Family Inference")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // The acronym is the only place the name is explained, so it must not
        // be shortened away on a narrow screen.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        // Label's own layout puts the icon beside a growing block of text and
        // clips it at accessibility sizes. Laid out explicitly so the icon can
        // fall above the text when the text needs the whole width.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.m) {
                symbol(icon)
                pointBody(title: title, detail: detail)
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                symbol(icon)
                pointBody(title: title, detail: detail)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.title2)
            .foregroundStyle(Brand.accent)
            .accessibilityHidden(true)
    }

    private func pointBody(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Start with an example")
                .font(.headline)
            ForEach(ExampleSequences.all) { example in
                Button {
                    store.load(text: example.fasta)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.title).font(.body.weight(.medium))
                        Text(example.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("boffin.onboarding.example.\(example.id)")
            }
        }
    }
}
