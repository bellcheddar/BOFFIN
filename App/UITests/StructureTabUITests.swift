//  StructureTabUITests.swift
//  BOFFINUITests

import XCTest

final class StructureTabUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Phase 7's first acceptance: 1UBQ loads from the bundle, offline, and the
    /// viewer reports the atom count the file actually holds.
    ///
    /// 660 is not a round number chosen for the test: it is 602 protein atoms
    /// and 58 waters, and it is what BoffinStructure's own parser reads out of
    /// the same file. If Mol* and the parser disagree, one of them is wrong and
    /// this is where that shows up.
    func testUbiquitinLoadsOfflineAndReportsItsAtomCount() throws {
        let app = XCUIApplication()
        app.launch()
        app.openTab("Structure")

        let viewer = app.descendants(matching: .any)
            .matching(identifier: "boffin.structure-viewer").firstMatch
        XCTAssertTrue(
            viewer.waitForExistence(timeout: 30), "the viewer never appeared")

        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 20), "no load control")
        load.tap()

        let count = app.staticTexts["660 atoms"]
        let failure = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "ViewerBridgeError")
        ).firstMatch

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !count.exists, !failure.exists {
            usleep(300_000)
        }
        XCTAssertFalse(
            failure.exists, "the bridge reported an error: \(failure.label)")
        XCTAssertTrue(
            count.exists,
            "1UBQ did not load, or reported an atom count other than 660")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Structure tab, 1UBQ"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The demo the build plan calls the most compelling thing in the app:
    /// BOFFIN's own per-residue analysis, painted onto the structure.
    ///
    /// The failure this guards against is silence. Painting sends a colour per
    /// residue through the bridge, and if Mol* rejects the custom colour theme
    /// the structure simply stays as it was, which looks identical to a track
    /// whose values happen to be flat.
    func testPaintingATrackOntoTheStructureReportsNoError() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Paste a sequence"].tap()
        app.buttons["Use the ubiquitin example"].tap()
        app.buttons["Analyse"].tap()
        XCTAssertTrue(
            app.staticTexts["76 residues \u{00B7} pasted"].waitForExistence(timeout: 15))

        app.openTab("Structure")
        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30))
        load.tap()
        XCTAssertTrue(
            app.staticTexts["660 atoms"].waitForExistence(timeout: 60),
            "the structure did not load")

        // Any continuous track will do; hydropathy is the one every sequence
        // has, because it needs no model.
        let track = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Hydropathy")
        ).firstMatch
        XCTAssertTrue(
            track.waitForExistence(timeout: 20),
            "no continuous track was offered for painting")
        track.tap()

        // The bridge reports failures into the state label, so an error here
        // would replace the atom count. Painting must leave it alone.
        XCTAssertTrue(
            app.staticTexts["660 atoms"].waitForExistence(timeout: 20),
            "painting the track put the viewer into an error state")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Structure tab, hydropathy painted onto 1UBQ"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Phase 9's acceptance in the interface: a profile, with its assumptions
    /// shown ABOVE the numbers rather than under them, and a way out to CSV.
    ///
    /// A reader who stops after the results has to have seen what they rest on,
    /// which is an argument about layout and not about wording.
    func testInteractionProfileShowsItsAssumptionsAndExports() throws {
        let app = XCUIApplication()
        app.launch()
        app.openTab("Structure")

        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30))
        load.tap()
        XCTAssertTrue(
            app.staticTexts["660 atoms"].waitForExistence(timeout: 60),
            "the structure did not load")

        let profile = app.buttons["boffin.profile-interactions"]
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "no profile control")
        profile.tap()

        let assumptions = app.staticTexts["boffin.interaction-assumptions"]
        XCTAssertTrue(
            assumptions.waitForExistence(timeout: 30),
            "the profile appeared without stating its assumptions")
        XCTAssertTrue(
            assumptions.label.contains("pH"),
            "the assumptions do not name the pH: \(assumptions.label)")
        XCTAssertTrue(
            assumptions.label.contains("hydrogens"),
            "the assumptions do not say whether hydrogens were present")

        XCTAssertTrue(
            app.buttons["boffin.share-interactions"].waitForExistence(timeout: 10),
            "the profile cannot be exported")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Structure tab, interaction profile"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Phase 8's remaining acceptance in the interface: a deck of scenes that
    /// presents, advances, and exports as `.pml`.
    func testSceneDeckCapturesPresentsAndExports() throws {
        let app = XCUIApplication()
        app.launch()
        app.openTab("Structure")

        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30))
        load.tap()
        XCTAssertTrue(app.staticTexts["660 atoms"].waitForExistence(timeout: 60))

        // Capture two scenes so advancing has somewhere to go.
        //
        // Deliberately WITHOUT typing a name. The first version typed one and
        // passed on iPhone while failing on iPad, because keyboard focus in a
        // text field inside a scrolling stack behaves differently between the
        // idioms: only one scene was captured, the deck showed "1 of 1", and the
        // failure looked like the advance logic. An untitled scene is named for
        // its position, which is what this test is about.
        let capture = app.buttons["boffin.capture-scene"]
        XCTAssertTrue(capture.waitForExistence(timeout: 20), "no capture control")
        capture.tap()
        capture.tap()
        XCTAssertTrue(
            app.staticTexts["2. Scene 2"].waitForExistence(timeout: 10),
            "two captures did not produce two scenes")

        XCTAssertTrue(
            app.buttons["boffin.export-pml"].waitForExistence(timeout: 10),
            "a deck with scenes cannot be exported")

        app.buttons["boffin.present-deck"].tap()

        // The position counter is the assertion, not the notes container. A
        // VStack carrying an accessibility identifier does not reliably surface
        // as `otherElements`, and the scene NAME is a poor probe because an
        // untitled scene is named for its position. The counter is text the
        // presenter actually reads.
        //
        // Advancing must stop at the end rather than wrapping: reaching the last
        // scene and finding the first again reads as having lost your place.
        XCTAssertTrue(
            app.staticTexts["1 of 2"].waitForExistence(timeout: 20),
            "presentation mode did not start")
        // Explicit controls, not a tap on the structure: in front of a room you
        // turn the molecule as often as you change slide, and a viewer that
        // advances when you try to rotate it is unusable exactly when it
        // matters. The first version tapped to advance and this test caught it,
        // because Mol* swallowed the tap and nothing happened.
        XCTAssertTrue(
            app.buttons["boffin.next-scene"].waitForExistence(timeout: 10),
            "no next control")
        app.buttons["boffin.next-scene"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["2 of 2"].waitForExistence(timeout: 10),
            "advancing did nothing")
        app.buttons["boffin.next-scene"].tap()
        XCTAssertTrue(app.staticTexts["2 of 2"].exists, "the deck wrapped past the end")
        app.buttons["boffin.previous-scene"].tap()
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 10))

        app.buttons["boffin.end-presentation"].tap()
        XCTAssertTrue(
            app.buttons["boffin.load-structure"].waitForExistence(timeout: 10),
            "dismissing the presentation did not return to the tab")
    }

}
