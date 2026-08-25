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
}
