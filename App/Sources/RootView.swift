//  RootView.swift
//  BOFFIN
//
//  The five tabs of the build plan. Only Order is implemented: the rest are
//  placeholders naming the phase that fills them, so the shape of the app is
//  visible without pretending the features exist.

import BoffinCore
import BoffinUI
import SwiftUI

struct RootView: View {
    @State private var store = SequenceStore()

    var body: some View {
        TabView {
            Tab("Order", systemImage: "waveform.path.ecg") {
                OrderTabView(store: store)
            }
            Tab("Fitness", systemImage: "square.grid.3x3") {
                FitnessTabView(store: store)
            }
            Tab("Family", systemImage: "point.3.connected.trianglepath.dotted") {
                FamilyTabView(store: store)
            }
            Tab("Boundary", systemImage: "scissors") {
                BoundaryTabView(store: store)
            }
            Tab("Structure", systemImage: "atom") {
                PlaceholderTab(
                    name: "Structure", phase: "Phase 7",
                    detail: "Interactive viewer with ResidueTrack painting.")
            }
        }
    }
}

struct PlaceholderTab: View {
    let name: String
    let phase: String
    let detail: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(name, systemImage: "hammer")
            } description: {
                VStack(spacing: Spacing.s) {
                    Text(detail)
                    Text("Arrives in \(phase).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle(name)
        }
    }
}

#Preview {
    RootView()
}
