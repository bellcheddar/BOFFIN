//  SceneDeckModel.swift
//  BoffinViewer
//
//  The scene deck's state, moved out of the app target.
//
//  It lived beside its SwiftUI views in the app, where it could not be tested:
//  the app's unit-test bundle is configured as a UI-test target, so a
//  `@testable import BOFFIN` fails to link, and `AppSmokeTests` had quietly
//  been asserting `Bool(true)` ever since. A test target that cannot reach the
//  code it names is worse than none, because the green tick is read as cover.
//
//  There is nothing about this type that needs to be in the app: it is scenes,
//  an index and a dictionary. Moving it here follows the project's own rule
//  that real behaviour is tested inside a package, and it runs under `swift
//  test` with no simulator.

import BoffinStructure
import Foundation
import Observation

@MainActor
@Observable
public final class SceneDeckModel {

    public init() {}
    public private(set) var scenes: [ViewerScene] = []
    /// Which scene is showing, or `nil` when the deck is not being presented.
    public private(set) var current: Int?

    public var isPresenting: Bool { current != nil }

    /// The scene being shown, or `nil` when the deck is not presenting.
    ///
    /// Bounds-checked rather than subscripted: `current` is an index into an
    /// array the user can delete from, and a deck emptied while presenting
    /// would otherwise trap.
    public var currentScene: ViewerScene? {
        guard let current, scenes.indices.contains(current) else { return nil }
        return scenes[current]
    }

    /// Pencil annotations, keyed by the scene's own identity.
    ///
    /// **Keyed by id, not by index**, and that is the whole correctness
    /// argument. The build plan says "anchored to scene index", but an index is
    /// not an anchor: `move(from:to:)` and `remove(at:)` both renumber every
    /// scene after the one they touch, so an annotation keyed by position would
    /// silently slide onto a different slide the first time a deck was
    /// reordered. Nothing would error, and the drawing would look perfectly
    /// deliberate on the wrong structure, in front of a room.
    ///
    /// Stored as PencilKit's own serialised form rather than as an image: a
    /// drawing is strokes, and strokes can be re-rendered at the display's
    /// resolution and edited later, while a flattened bitmap can do neither.
    public private(set) var annotations: [ViewerScene.ID: Data] = [:]

    /// Record, replace, or clear the annotation for a scene.
    ///
    /// Empty data clears rather than storing nothing, so "the user rubbed it
    /// all out" and "there was never a drawing" end up the same state instead
    /// of two states that render identically.
    public func annotate(_ scene: ViewerScene.ID, with drawing: Data) {
        if drawing.isEmpty {
            annotations.removeValue(forKey: scene)
        } else {
            annotations[scene] = drawing
        }
    }

    public func annotation(for scene: ViewerScene.ID) -> Data? { annotations[scene] }

    /// The annotation for the scene being presented, if any.
    public var currentAnnotation: Data? {
        guard let index = current, scenes.indices.contains(index) else { return nil }
        return annotations[scenes[index].id]
    }

    public func capture(
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

    public func remove(at offsets: IndexSet) {
        // Drop the annotations with their scenes. An orphaned drawing is
        // invisible, unreachable and would reappear if an id were ever reused.
        for offset in offsets where scenes.indices.contains(offset) {
            annotations.removeValue(forKey: scenes[offset].id)
        }
        scenes.remove(atOffsets: offsets)
        if scenes.isEmpty { current = nil }
    }

    public func move(from source: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: source, toOffset: destination)
    }

    public func present() {
        guard !scenes.isEmpty else { return }
        current = 0
    }

    public func dismiss() { current = nil }

    /// Advance, stopping at the end rather than wrapping.
    ///
    /// Wrapping is the wrong default in front of a room: reaching the end and
    /// finding the first slide again reads as having lost your place.
    public func advance() {
        guard let index = current else { return }
        current = min(index + 1, scenes.count - 1)
    }

    public func retreat() {
        guard let index = current else { return }
        current = max(index - 1, 0)
    }

    public var script: String {
        PyMOLScript.export(scenes, structureName: "structure")
    }
}
