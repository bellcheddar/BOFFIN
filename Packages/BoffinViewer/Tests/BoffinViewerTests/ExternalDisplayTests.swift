//  ExternalDisplayTests.swift
//  BoffinViewerTests
//
//  The routing cannot be verified without a projector, so what can be tested
//  is tested here: which scene roles get the presenter output, and that the
//  bridge keeps the structure across a disconnect.

import BoffinStructure
import Foundation
import Testing

@testable import BoffinViewer

@Suite("External display")
struct ExternalDisplayTests {

    @Test("Only the external-display role gets the presenter")
    func routing() {
        #expect(ExternalDisplay.isPresenterScene(role: ExternalDisplay.presenterRole))
        #expect(!ExternalDisplay.isPresenterScene(role: ExternalDisplay.deviceRole))
    }

    @Test(
        "An unknown role falls through to the normal interface",
        arguments: [
            "UIWindowSceneSessionRoleCarTemplateApplication",
            "UIWindowSceneSessionRoleSomethingAddedLater",
            "",
        ])
    func unknownRolesAreNotPresenters(role: String) {
        // Not "anything that is not the application role". Guessing wrong in
        // that direction puts a protein structure on a car dashboard.
        #expect(!ExternalDisplay.isPresenterScene(role: role))
    }

    @MainActor
    @Test("The structure survives the projector being unplugged")
    func structureSurvivesDetach() {
        let bridge = PresentationBridge()
        let data = Data([0x83, 0xa7, 0x76])
        bridge.load(data, format: .binaryCIF, title: "1UBQ")
        bridge.attach()
        bridge.present(ViewerScene(name: "Active site", notes: "the triad"))

        #expect(bridge.isAttached)
        #expect(bridge.scene?.name == "Active site")

        bridge.detach()
        // A cable pulled out mid-talk and pushed back in should resume, so the
        // structure is deliberately not cleared with the attachment.
        #expect(!bridge.isAttached)
        #expect(bridge.structure == data)
        #expect(bridge.title == "1UBQ")
    }

    @MainActor
    @Test("Presenting nothing is distinct from having nothing to present")
    func presentingNilIsNotEmpty() {
        let bridge = PresentationBridge()
        bridge.load(Data([0x01]), format: .binaryCIF, title: "1UBQ")
        bridge.present(nil)
        // A deck can be presented with no projector and a projector attached
        // with no deck, so these two states must not be inferred from each
        // other.
        #expect(bridge.scene == nil)
        #expect(bridge.structure != nil)
        #expect(!bridge.isAttached)
    }
}

@Suite("Deck presentation state")
struct DeckPresentationTests {

    @MainActor
    @Test("A deck emptied while presenting reports no scene rather than trapping")
    func emptiedWhilePresenting() {
        // `current` is an index into an array the user can delete from, and
        // the projector reads it on every change. Subscripting it directly
        // would take the app down in front of a room.
        let deck = SceneDeckModel()
        deck.capture(
            name: "Overview", selection: nil, representation: .cartoon,
            colourTheme: .chain, notes: "")
        deck.capture(
            name: "Active site", selection: nil, representation: .cartoon,
            colourTheme: .chain, notes: "")
        deck.present()
        #expect(deck.currentScene?.name == "Overview")

        deck.remove(at: IndexSet([0, 1]))
        #expect(deck.currentScene == nil)
        #expect(deck.scenes.isEmpty)
    }

    @MainActor
    @Test("Advancing stops at the end rather than wrapping")
    func advanceStops() {
        let deck = SceneDeckModel()
        deck.capture(
            name: "One", selection: nil, representation: .cartoon,
            colourTheme: .chain, notes: "")
        deck.capture(
            name: "Two", selection: nil, representation: .cartoon,
            colourTheme: .chain, notes: "")
        deck.present()
        deck.advance()
        deck.advance()
        #expect(deck.currentScene?.name == "Two")
    }
}
