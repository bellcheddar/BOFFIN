//  NeuralEngineBar.swift
//  BoffinUI
//
//  A slim strip across the top of the app showing the Neural Engine working.
//
//  The point is demonstration: the whole premise of BOFFIN is that a protein
//  language model runs in your pocket, and that is invisible when it works.
//  This makes it visible WITHOUT claiming anything unmeasured -- see
//  `NeuralEngineStatus` for why there is no utilisation percentage here.

import SwiftUI

public struct NeuralEngineBar: View {

    private let status: NeuralEngineStatus
    @State private var pulse = false
    /// Respected rather than ignored: a pulsing dot is exactly the sort of
    /// thing that makes an app unusable for someone who has asked the system
    /// to stop moving things.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: NeuralEngineStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            indicator
            Text(status.activity.label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            if case .scanning(let fraction) = status.activity {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 90)
            }
            Spacer(minLength: 0)
            if let detail = status.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status.activity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("boffin.ane-bar")
    }

    private var indicator: some View {
        Circle()
            .fill(status.activity.isActive ? Brand.accent : Color.secondary)
            .frame(width: 7, height: 7)
            .scaleEffect(pulse && status.activity.isActive && !reduceMotion ? 1.45 : 1)
            .opacity(status.activity.isActive ? 1 : 0.45)
            .animation(
                reduceMotion || !status.activity.isActive
                    ? nil
                    : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }

    private var background: some View {
        // Tinted only while working, so the strip recedes when it has nothing
        // to report rather than sitting there as permanent chrome.
        (status.activity.isActive
            ? Brand.accent.opacity(0.12)
            : Color.clear)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status.activity)
    }

    /// One spoken sentence rather than four fragments.
    ///
    /// VoiceOver reads the elements of an HStack in order, which here would be
    /// a dot, a label, a progress bar and a count as four separate stops. The
    /// children are ignored and this is said instead.
    private var accessibilityLabel: String {
        var parts = [status.activity.label]
        if case .scanning(let fraction) = status.activity {
            parts.append("\(Int(fraction * 100)) per cent complete")
        }
        if let detail = status.detail { parts.append(detail) }
        parts.append(
            "\(NeuralEngineStatus.scheduledOnANE) of "
                + "\(NeuralEngineStatus.totalOperations) model operations are scheduled "
                + "on the Neural Engine")
        return parts.joined(separator: ". ")
    }
}
