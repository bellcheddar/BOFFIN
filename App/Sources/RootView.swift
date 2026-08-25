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
    @State private var openError: String?

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
                StructureTabView(store: store)
            }
        }
        // A FASTA shared from Mail, Files or AirDrop. The plist half of this is
        // in Info.plist and is the half that is invisible when it is missing:
        // without CFBundleDocumentTypes the share sheet never offers BOFFIN and
        // this closure is never called, which reads as a bug in the handler.
        .onOpenURL { url in
            do {
                let text = try OpenedDocument.read(url)
                store.load(text: text, fileName: url.lastPathComponent)
                openError = nil
            } catch let failure as OpenedDocument.Failure {
                openError = failure.message
            } catch {
                openError = String(describing: error)
            }
        }
        .alert(
            "Could not open that file", isPresented: openAlert,
            actions: { Button("OK") { openError = nil } },
            message: { Text(openError ?? "") })
    }

    private var openAlert: Binding<Bool> {
        Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })
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
