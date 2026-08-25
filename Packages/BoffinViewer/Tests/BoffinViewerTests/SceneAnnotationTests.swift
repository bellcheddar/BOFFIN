//  SceneAnnotationTests.swift
//  BoffinViewerTests
//
//  Pencil annotations have to stay attached to the scene they were drawn on.
//
//  The build plan says "anchored to scene index". An index is not an anchor:
//  reordering or deleting a scene renumbers every scene after it, so an
//  annotation keyed by position slides onto a different slide. Nothing errors,
//  and the drawing looks perfectly deliberate on the wrong structure, in front
//  of a room. These tests are the reason the key is the scene's own identity.
//
//  They live here rather than in the app's own test bundle because that bundle
//  is configured as a UI-test target and cannot link the app's symbols, which
//  is why its one existing test asserts `Bool(true)`. `SceneDeckModel` is
//  scenes, an index and a dictionary, so it belongs in a package where it can
//  be tested without a simulator.

import BoffinStructure
import Foundation
import Testing

@testable import BoffinViewer

@MainActor
@Suite("Scene annotations")
struct SceneAnnotationTests {

    private func deck(_ names: [String]) -> SceneDeckModel {
        let model = SceneDeckModel()
        for name in names {
            model.capture(
                name: name, selection: nil, representation: .cartoon,
                colourTheme: .chain, notes: "")
        }
        return model
    }

    @Test("An annotation follows its scene when the deck is reordered")
    func annotationSurvivesReordering() {
        // The failure this exists for: draw on the active site slide, reorder
        // the deck, and present to a room with the circle now over an unrelated
        // structure.
        let model = deck(["Overview", "Active site", "Mutation"])
        let activeSite = model.scenes[1].id
        model.annotate(activeSite, with: Data([1, 2, 3]))

        model.move(from: IndexSet(integer: 1), to: 0)

        #expect(model.scenes[0].name == "Active site", "the move did not happen")
        #expect(
            model.annotation(for: activeSite) == Data([1, 2, 3]),
            "the annotation did not follow its scene")
        // And nothing landed on the neighbours.
        #expect(model.annotation(for: model.scenes[1].id) == nil)
        #expect(model.annotation(for: model.scenes[2].id) == nil)
    }

    @Test("Two scenes with the same name keep separate annotations")
    func duplicateNamesDoNotCollide() {
        // `id` used to be `name`, so this case silently shared one drawing
        // between two slides. Naming two scenes "Site" is not a mistake a user
        // should have to avoid.
        let model = deck(["Site", "Site"])
        #expect(model.scenes[0].id != model.scenes[1].id, "identities collided")

        model.annotate(model.scenes[0].id, with: Data([1]))
        model.annotate(model.scenes[1].id, with: Data([2]))

        #expect(model.annotation(for: model.scenes[0].id) == Data([1]))
        #expect(model.annotation(for: model.scenes[1].id) == Data([2]))
    }

    @Test("Deleting a scene takes its annotation with it")
    func deletingRemovesTheAnnotation() {
        // An orphaned drawing is invisible, unreachable, and would reappear if
        // an identity were ever reused.
        let model = deck(["One", "Two"])
        let doomed = model.scenes[1].id
        model.annotate(doomed, with: Data([9]))

        model.remove(at: IndexSet(integer: 1))

        #expect(model.annotation(for: doomed) == nil)
        #expect(model.annotations.isEmpty)
    }

    @Test("Rubbing an annotation out clears it rather than storing nothing")
    func emptyDrawingClears() {
        // "The user rubbed it all out" and "there was never a drawing" must end
        // up the same state, or an empty drawing lingers and the two render
        // identically while comparing unequal.
        let model = deck(["One"])
        let scene = model.scenes[0].id
        model.annotate(scene, with: Data([1, 2]))
        #expect(model.annotation(for: scene) != nil)

        model.annotate(scene, with: Data())
        #expect(model.annotation(for: scene) == nil)
        #expect(model.annotations.isEmpty)
    }

    @Test("The presented scene's annotation is the one that comes back")
    func currentAnnotationTracksPresentation() {
        let model = deck(["One", "Two"])
        model.annotate(model.scenes[1].id, with: Data([7]))

        model.present()
        #expect(model.currentAnnotation == nil, "slide one has no annotation")

        model.advance()
        #expect(model.currentAnnotation == Data([7]))

        model.dismiss()
        #expect(model.currentAnnotation == nil, "nothing is being presented")
    }

    @Test("Scenes still compare by content, so .pml round trips are unaffected")
    func identityDoesNotBreakContentEquality() {
        // Identity and content are different questions. A scene exported to a
        // .pml file and read back is a different object with the same content,
        // and the export tests are right to call those equal. Including the
        // identity in equality would fail every round trip for a reason that
        // has nothing to do with the file.
        let a = ViewerScene(name: "Site", notes: "hinge")
        let b = ViewerScene(name: "Site", notes: "hinge")
        #expect(a.id != b.id, "identities should be distinct")
        #expect(a == b, "content equality broke, which breaks .pml round trips")
        #expect(Set([a, b]).count == 1, "hashing disagrees with equality")
    }
}
