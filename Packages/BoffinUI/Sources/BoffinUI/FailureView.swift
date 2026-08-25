//  FailureView.swift
//  BoffinUI
//
//  How a `UserFacingError` is shown.
//
//  The layout encodes the priority: what did not happen, then what to do about
//  it, then the raw text behind a disclosure that starts closed. A scientist
//  who wants the Core ML error code can have it in one tap and can copy it into
//  a bug report; everyone else never sees it.
//
//  The detail is selectable and copyable rather than merely displayed, because
//  the whole reason for keeping it is that someone may need to send it
//  somewhere, and text you can read but not copy is text you have to retype
//  from a photograph of your own screen.

import BoffinCore
import SwiftUI

public struct FailureView: View {
    private let failure: UserFacingError
    private let icon: String
    /// Shown as a button under the message, when there is something to retry.
    private let retry: (() -> Void)?

    @State private var isShowingDetail = false

    public init(
        _ failure: UserFacingError,
        icon: String = "exclamationmark.triangle",
        retry: (() -> Void)? = nil
    ) {
        self.failure = failure
        self.icon = icon
        self.retry = retry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(failure.summary)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(ScientificPalette.warning)
            }

            if let recovery = failure.recovery {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("boffin.failure.retry")
            }

            DisclosureGroup("Technical detail", isExpanded: $isShowingDetail) {
                Text(failure.detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.xs)
                    .accessibilityIdentifier("boffin.failure.detail")
            }
            .font(.caption)
            .accessibilityIdentifier("boffin.failure.disclosure")
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ScientificPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boffin.failure")
    }
}
