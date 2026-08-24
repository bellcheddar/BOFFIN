//  RootView.swift
//  BOFFIN
//
//  Phase 0 placeholder. Phase 1 replaces this with the sequence spine, and the
//  tab structure (Order, Fitness, Family, Boundary, Structure) arrives with
//  the phases that fill each tab.

import BoffinCore
import BoffinUI
import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: Spacing.m) {
            Text("BOFFIN")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Brand.accent)
            Text("Boundary, Order, Fitness and Family INference")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Research use only.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.l)
    }
}

#Preview {
    RootView()
}
