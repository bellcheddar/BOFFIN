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

struct SceneDeckView: View {
    @Bindable var model: SceneDeckModel
    @Bindable private var bridge = PresentationBridge.shared
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
                    // `isAttached` said in its own doc comment that the
                    // device side would offer presenter controls only when
                    // there was somewhere to present, and nothing on the
                    // device side read it. Now the button says where the
                    // deck is going, which is the difference between
                    // presenting to a room and presenting to your own hand.
                    Button(bridge.isAttached ? "Present on display" : "Present") {
                        model.present()
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption2)
                    .minimumTouchTarget()
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
            .minimumTouchTarget()
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
        // Mirror to the projector.
        //
        // Driven from here rather than from inside StructureViewerModel: the
        // package would otherwise hold a reference to a shared singleton, and
        // the module rule exists to stop exactly that. The deck is the one
        // place that knows both what is loaded and which scene is showing.
        .onChange(of: viewer.loadedData) { _, data in
            guard let data else { return }
            PresentationBridge.shared.load(
                data, format: viewer.loadedFormat, title: viewer.source?.label ?? "")
        }
        .onChange(of: model.current) { _, _ in
            PresentationBridge.shared.present(model.currentScene)
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

    /// Whether the Pencil canvas is taking input.
    ///
    /// Off by default, and this is the important half: in front of a room you
    /// rotate the molecule far more often than you annotate it, so a canvas
    /// that is always live would swallow every drag meant for the structure.
    /// The annotation stays VISIBLE when input is off, so turning it off is
    /// putting the pen down rather than rubbing the drawing out.
    @State private var isAnnotating = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            StructureViewerView(model: viewer).ignoresSafeArea()

            if let index = model.current, model.scenes.indices.contains(index) {
                let scene = model.scenes[index]
                if isAnnotating {
                    // The live canvas exists ONLY while the pen is up.
                    //
                    // `PKCanvasView` is a `UIScrollView` subclass, and merely
                    // having one in the hierarchy took an accessibility query
                    // in the presentation test from 24 seconds to 188 and then
                    // to a TIMEOUT: "failed to get matching snapshots", which
                    // reads as a broken deck rather than a busy tree. Marking
                    // it hidden was not enough, because the view is still
                    // there to be walked.
                    //
                    // Annotating is the rare state and rotating is the common
                    // one, so the rare state pays the cost.
                    AnnotationCanvas(
                        drawing: annotationBinding(for: scene.id), isActive: true
                    )
                    .ignoresSafeArea()
                } else if let strokes = model.annotation(for: scene.id),
                    let image = AnnotationCanvas.render(strokes)
                {
                    // Put the pen down and the drawing stays: it is rendered
                    // from the same strokes rather than rubbed out. Strokes
                    // remain the stored form, so this is a view of the data and
                    // not a second copy of it.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
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
                            isAnnotating.toggle()
                        } label: {
                            Image(systemName: isAnnotating ? "pencil.circle.fill" : "pencil.circle")
                                .font(.title3)
                                .padding(.horizontal, Spacing.s)
                                .padding(.vertical, Spacing.s)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("boffin.annotate-toggle")
                        .accessibilityLabel(isAnnotating ? "Put the pen down" : "Annotate")

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

    /// Read and write the annotation for one scene.
    ///
    /// Written through the model rather than held in view state, so the drawing
    /// survives leaving the presentation and comes back attached to the same
    /// scene rather than to whatever is now in that position.
    private func annotationBinding(for scene: ViewerScene.ID) -> Binding<Data> {
        Binding(
            get: { model.annotation(for: scene) ?? Data() },
            set: { model.annotate(scene, with: $0) })
    }
}
