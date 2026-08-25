//  SceneDeck.swift
//  BOFFIN
//
//  Phase 8's scene deck: named states, ordered, presentable, exportable.
//
//  A deck is the PyMOL session concept made touch-native. What makes it worth
//  having on a phone rather than on a laptop is that it goes into a pocket and
//  comes out in front of a room, so the two things it must do well are advance
//  reliably and travel: `.pml` out, and the notes with it.

import BoffinCore
import BoffinStructure
import BoffinUI
import BoffinViewer
import SwiftUI

@MainActor
@Observable
final class SceneDeckModel {
    private(set) var scenes: [ViewerScene] = []
    /// Which scene is showing, or `nil` when the deck is not being presented.
    private(set) var current: Int?

    var isPresenting: Bool { current != nil }

    func capture(
        name: String, selection: String?, representation: ViewerRepresentation,
        colourTheme: ViewerColourTheme, notes: String
    ) {
        scenes.append(
            ViewerScene(
                name: name.isEmpty ? "Scene \(scenes.count + 1)" : name,
                selection: selection,
                representation: representation.rawValue,
                colourTheme: colourTheme.rawValue,
                notes: notes))
    }

    func remove(at offsets: IndexSet) {
        scenes.remove(atOffsets: offsets)
        if scenes.isEmpty { current = nil }
    }

    func move(from source: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: source, toOffset: destination)
    }

    func present() {
        guard !scenes.isEmpty else { return }
        current = 0
    }

    func dismiss() { current = nil }

    /// Advance, stopping at the end rather than wrapping.
    ///
    /// Wrapping is the wrong default in front of a room: reaching the end and
    /// finding the first slide again reads as having lost your place.
    func advance() {
        guard let index = current else { return }
        current = min(index + 1, scenes.count - 1)
    }

    func retreat() {
        guard let index = current else { return }
        current = max(index - 1, 0)
    }

    var script: String {
        PyMOLScript.export(scenes, structureName: "structure")
    }
}

struct SceneDeckView: View {
    @Bindable var model: SceneDeckModel
    let viewer: StructureViewerModel
    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var selection: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                if !model.scenes.isEmpty {
                    ShareLink(item: model.script) {
                        Label("Export .pml", systemImage: "square.and.arrow.up")
                            .font(.caption2)
                    }
                    .accessibilityIdentifier("boffin.export-pml")
                    Button("Present") { model.present() }
                        .buttonStyle(.borderedProminent)
                        .font(.caption2)
                        .accessibilityIdentifier("boffin.present-deck")
                }
            }

            TextField("Scene name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityIdentifier("boffin.scene-name")
            TextField("Selection (optional)", text: $selection)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
            TextField("Presenter notes", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(1...3)

            Button("Capture scene") {
                model.capture(
                    name: name, selection: selection.isEmpty ? nil : selection,
                    representation: viewer.representation,
                    colourTheme: viewer.colourTheme, notes: notes)
                name = ""
                notes = ""
            }
            .buttonStyle(.bordered)
            .font(.caption2)
            .accessibilityIdentifier("boffin.capture-scene")

            ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                HStack {
                    Text("\(index + 1). \(scene.name)")
                        .font(.caption)
                    if scene.selection != nil {
                        Image(systemName: "scope").font(.caption2)
                            .foregroundStyle(Brand.accent)
                    }
                    Spacer()
                    Text(scene.representation)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .fullScreenCover(isPresented: presenting) {
            PresentationView(model: model, viewer: viewer)
        }
    }

    private var presenting: Binding<Bool> {
        Binding(get: { model.isPresenting }, set: { if !$0 { model.dismiss() } })
    }
}

/// Full-bleed, chrome-free, and driven by swipes or arrow keys.
///
/// The notes are on screen for the presenter and would be on the projector too,
/// which is wrong: a presenter view belongs on the device and the structure
/// belongs on the display. That split needs an external screen to develop
/// against, so for now the notes are shown and labelled as the presenter's.
struct PresentationView: View {
    @Bindable var model: SceneDeckModel
    let viewer: StructureViewerModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            StructureViewerView(model: viewer).ignoresSafeArea()
            #endif

            if let index = model.current, index < model.scenes.count {
                let scene = model.scenes[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("boffin.presentation-notes")
                    if !scene.notes.isEmpty {
                        Text(scene.notes)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("\(index + 1) of \(model.scenes.count)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        // The controls live INSIDE the notes panel rather than
                        // in their own overlay over the web view. As a separate
                        // overlay they were reachable on iPhone and not on iPad,
                        // where the web view's own gesture area covered them:
                        // the test tapped, nothing advanced, and the failure
                        // looked like the deck logic.
                        Button {
                            model.retreat()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title3)
                                .padding(.horizontal, Spacing.m)
                                .padding(.vertical, Spacing.s)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("boffin.previous-scene")
                        .accessibilityLabel("Previous scene")

                        Button {
                            model.advance()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.title3)
                                .padding(.horizontal, Spacing.m)
                                .padding(.vertical, Spacing.s)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("boffin.next-scene")
                        .accessibilityLabel("Next scene")
                    }
                    .foregroundStyle(.white)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.55))
                // No identifier on this container. An accessibility identifier
                // on a stack makes the whole stack ONE element and hides the
                // buttons inside it, so the scene controls simply vanished from
                // the tree and the failure read as "no next control" against a
                // view that visibly has one.
            }
        }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width < 0 { model.advance() } else { model.retreat() }
                }
        )
        // Explicit controls as well as the swipe, and NOT tap-to-advance.
        //
        // A tap on the structure belongs to the structure: in front of a room
        // you turn the molecule as often as you change slide, and a viewer that
        // changes slide when you try to rotate it is unusable exactly when it
        // matters. The first version tapped to advance and a test caught it,
        // because Mol* swallowed the tap and nothing happened.
        .overlay(alignment: .topTrailing) {
            Button("Done") { model.dismiss() }
                .padding()
                .foregroundStyle(.white)
                .accessibilityIdentifier("boffin.end-presentation")
        }
    }
}
