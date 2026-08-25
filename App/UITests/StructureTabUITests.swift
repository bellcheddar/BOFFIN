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
        app.launchSkippingOnboarding()
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
        app.launchSkippingOnboarding()

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
        app.launchSkippingOnboarding()
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
        app.launchSkippingOnboarding()
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

    /// The check no benchmark can make: the head predicts from sequence alone
    /// and the loaded structure says what the backbone actually does.
    ///
    /// Agreement is not a score for the head. It is a statement about THIS
    /// protein, which is what a user needs when deciding whether to trust a
    /// track on the ruler.
    func testPredictionIsComparedAgainstTheStructuresOwnGeometry() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        app.buttons["Paste a sequence"].tap()
        app.buttons["Use the ubiquitin example"].tap()
        app.buttons["Analyse"].tap()
        XCTAssertTrue(
            app.staticTexts["76 residues \u{00B7} pasted"].waitForExistence(timeout: 15))

        app.openTab("Structure")
        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30))
        load.tap()
        XCTAssertTrue(app.staticTexts["660 atoms"].waitForExistence(timeout: 60))

        let agreement = app.staticTexts["boffin.structure-agreement"]
        // Absent when the model is not bundled, which is a legitimate state and
        // not a failure: the comparison needs a prediction to compare.
        if agreement.waitForExistence(timeout: 30) {
            XCTAssertTrue(
                agreement.label.contains("agrees with the structure"),
                "unexpected wording: \(agreement.label)")
            XCTAssertTrue(
                agreement.label.contains("three state"),
                "the comparison does not say which alphabet it used")
        }
    }
}

// MARK: - Figure export

extension StructureTabUITests {

    /// Phase 7's export acceptance: a real PNG, at the size that was asked for.
    ///
    /// This test exists in the shape it does because of the 3D interaction
    /// overlay, which was built twice and removed twice, and whose tests passed
    /// throughout. They asserted that a command was DISPATCHED. It was, every
    /// time, and it drew nothing.
    ///
    /// So this asserts none of the following: that the button exists, that the
    /// command returned, that no error appeared. It reads the size the app
    /// parsed out of the PNG's own IHDR header and compares it with the size
    /// requested. That number can only be right if Mol* really rendered
    /// offscreen at that resolution and really handed back PNG bytes, which is
    /// the entire claim.
    func testFigureExportProducesAPNGAtTheRequestedSize() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.openTab("Structure")

        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30), "no load control")
        load.tap()
        XCTAssertTrue(
            app.staticTexts["660 atoms"].waitForExistence(timeout: 60),
            "the structure never loaded, so there is nothing to render")

        let export = app.buttons["boffin.export.1 column"]
        XCTAssertTrue(
            export.waitForExistence(timeout: 20), "the figure export control is missing")
        export.tap()

        // Rendering offscreen at 1016 x 762 takes a moment on a simulator.
        let size = app.staticTexts["boffin.export.size"]
        XCTAssertTrue(
            size.waitForExistence(timeout: 90),
            "no figure came back, and no error was shown either")

        // 1016 x 762 is the single-column size the button asks for. Reading it
        // back out of the file is the whole point: a renderer that silently
        // clamped to the viewport would show the viewport's size here, and a
        // handler that returned something that is not a PNG would show the
        // "not a PNG" message instead.
        XCTAssertEqual(
            size.label, "1016 x 762 PNG",
            "the exported file is not the figure that was requested")

        // And it is shareable, which is the only reason a user pressed the
        // button. A figure that renders and cannot leave the device is not a
        // figure.
        XCTAssertTrue(
            app.buttons["boffin.export.share"].exists,
            "the rendered figure cannot be shared anywhere")
    }
}

// MARK: - The 3D interaction overlay

extension StructureTabUITests {

    /// Phase 9's last acceptance, and the one that has failed twice before.
    ///
    /// The overlay was built and removed twice. The second attempt measured
    /// **0 of 40 lines drawn**, and every test in the suite passed throughout,
    /// because they asserted that a command had been DISPATCHED. It was. It
    /// resolved both endpoints to empty selections and the state cell reported
    /// success.
    ///
    /// So this test asserts the count. Not that the button worked, not that no
    /// error appeared, not that a command was sent: the number of contacts that
    /// actually reached the structure, compared against the number the profiler
    /// found. Those two agreeing is the entire claim, and it is the only thing
    /// that distinguishes a working overlay from one drawing nothing, since
    /// both look identical on screen.
    func testInteractionOverlayActuallyDrawsWhatItProfiled() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.openTab("Structure")

        // The profiling control only exists once the viewer is up, so the
        // structure has to be loaded first.
        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30), "no load control")
        load.tap()
        XCTAssertTrue(
            app.staticTexts["660 atoms"].waitForExistence(timeout: 60),
            "the structure never loaded")

        let profile = app.buttons["boffin.profile-interactions"]
        XCTAssertTrue(profile.waitForExistence(timeout: 30), "no profiling control")
        profile.tap()

        let count = app.staticTexts["boffin.overlay.count"]
        XCTAssertTrue(
            count.waitForExistence(timeout: 90),
            "no overlay count appeared, so nothing was even attempted")

        // "N of M drawn in 3D". Both numbers must be non-zero and equal: a
        // profile with contacts in it, all of which reached the structure.
        let parts = count.label.split(separator: " ")
        guard parts.count >= 3, let drawn = Int(parts[0]), let requested = Int(parts[2]) else {
            return XCTFail("could not read the overlay count from \(count.label)")
        }

        XCTAssertGreaterThan(
            requested, 0,
            "the profiler found no contacts on CDK2's ATP site, so this test proves nothing")
        XCTAssertEqual(
            drawn, requested,
            "the overlay drew \(drawn) of \(requested) contacts: "
                + "endpoints are not resolving, which is how this shipped broken twice")
    }
}

extension StructureTabUITests {

    /// Loading a structure REPLACES the previous one.
    ///
    /// `loadStructureFromData` adds to the hierarchy rather than clearing it,
    /// and every read in the bridge indexes `structures[0]`, which stays the
    /// first structure ever loaded. So after a second load the viewer showed
    /// the new molecule while every query answered about the old one.
    ///
    /// This is the defect that made the 3D interaction overlay fail twice. It
    /// was diagnosed both times as a selection-language problem, and the
    /// selection language was innocent: the endpoints were being resolved
    /// against ubiquitin while the profile had been computed on a kinase.
    ///
    /// It is tested here on the atom count rather than through the overlay,
    /// because the count is the simplest observable that distinguishes the two
    /// structures, and because a bug this general should not be guarded only by
    /// the one feature that happened to expose it.
    func testLoadingASecondStructureReplacesTheFirst() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.openTab("Structure")

        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30), "no load control")
        load.tap()
        XCTAssertTrue(
            app.staticTexts["660 atoms"].waitForExistence(timeout: 60),
            "ubiquitin did not load")

        // Profiling loads CDK2, which has 2,510 atoms.
        let profile = app.buttons["boffin.profile-interactions"]
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "no profiling control")
        profile.tap()

        // Formatted the same way the label formats it, rather than hardcoded:
        // the count is rendered with `.formatted()`, so 2,510 carries a
        // separator in this locale and would carry a different one in another.
        // 660 has no separator, which is exactly why the existing single-load
        // test never noticed.
        let kinase = "\(2510.formatted()) atoms"
        XCTAssertTrue(
            app.staticTexts[kinase].waitForExistence(timeout: 60),
            "the viewer still reports ubiquitin's atom count after loading a kinase, "
                + "so the structures are accumulating instead of replacing")
        XCTAssertFalse(
            app.staticTexts["\(660.formatted()) atoms"].exists,
            "both structures are present at once")
    }
}

extension StructureTabUITests {

    /// Phase 8: the selection language is optional.
    ///
    /// The builder writes the SAME expression a user could type, rather than
    /// maintaining a parallel model of what is selected. So this test asserts
    /// on the expression text and on the live count, which together prove the
    /// two halves that matter: the taps produce valid syntax, and that syntax
    /// matches something real in the loaded structure.
    ///
    /// The count is the half that would otherwise rot silently. A builder that
    /// composes a perfectly grammatical expression matching nothing at all is
    /// the failure that looks most like success, and it is what puts an empty
    /// figure in front of someone.
    func testSelectionBuilderComposesAWorkingExpression() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.openTab("Structure")

        let load = app.buttons["boffin.load-structure"]
        XCTAssertTrue(load.waitForExistence(timeout: 30), "no load control")
        load.tap()
        XCTAssertTrue(
            app.staticTexts["\(660.formatted()) atoms"].waitForExistence(timeout: 60),
            "the structure never loaded")

        let build = app.buttons["boffin.selection.build"]
        XCTAssertTrue(build.waitForExistence(timeout: 20), "no selection builder control")
        build.tap()

        // Tap a category. Ubiquitin is all polymer, so this must match a lot.
        let polymer = app.buttons["boffin.selection.token.polymer"]
        XCTAssertTrue(polymer.waitForExistence(timeout: 20), "the builder offered no categories")
        polymer.tap()

        let count = app.staticTexts["boffin.selection.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), "no live count")
        XCTAssertTrue(
            count.label.contains("atoms"),
            "the builder composed something that does not match atoms: \(count.label)")
        XCTAssertFalse(
            count.label.lowercased().contains("matches nothing"),
            "`polymer` matched nothing in ubiquitin, which is all polymer")

        // Now wrap it, which is the part that is genuinely painful to type.
        let byres = app.buttons["boffin.selection.byres"]
        XCTAssertTrue(byres.exists, "no byres control")
        byres.tap()

        XCTAssertFalse(
            count.label.lowercased().contains("not a selection keyword"),
            "wrapping produced invalid syntax: \(count.label)")
        XCTAssertTrue(
            count.label.contains("atoms"),
            "the wrapped expression stopped matching: \(count.label)")
    }
}
