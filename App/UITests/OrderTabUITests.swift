//  OrderTabUITests.swift
//  BOFFINUITests
//
//  Phase 1 acceptance, driven the way a user would: paste a sequence, see it
//  rendered on the ruler with analytical properties beside it.

import XCTest

final class OrderTabUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testPasteASequenceAndSeeItAnalysed() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        // The empty state offers the way in.
        let pasteButton = app.buttons["Paste a sequence"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 10), "empty state did not appear")
        pasteButton.tap()

        // Use the bundled ubiquitin example rather than typing 76 residues
        // through the simulator keyboard.
        let example = app.buttons["Use the ubiquitin example"]
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        example.tap()

        app.tapButton("Analyse")

        // The header reports what was parsed.
        let header = app.staticTexts["76 residues \u{00B7} pasted"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "sequence header did not appear")

        // The analytical panel is populated, and the numbers are the published
        // ones for ubiquitin rather than placeholders.
        XCTAssertTrue(
            app.staticTexts["8564.74 Da"].waitForExistence(timeout: 5),
            "molecular weight missing or wrong")
        XCTAssertTrue(app.staticTexts["6.56"].exists, "isoelectric point missing or wrong")
        XCTAssertTrue(app.staticTexts["36.06"].exists, "instability index missing or wrong")

        // The ruler is present. Queried across every element type by
        // identifier: SwiftUI decides for itself whether a scrollable Canvas
        // surfaces as a scrollView, an otherElement or something else, and
        // pinning the test to one of those is a guess that breaks on an OS
        // update rather than on a real regression.
        let ruler = app.descendants(matching: .any)
            .matching(identifier: "boffin.residue-ruler").firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 5), "the ruler was not rendered")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Order tab with ubiquitin"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEmptyInputIsRejectedGracefully() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        app.tapButton("Paste a sequence")
        // Analyse must be disabled with nothing typed, rather than producing an
        // empty sequence or an error the user has to dismiss.
        XCTAssertFalse(app.buttons["Analyse"].isEnabled)
    }

    /// Every source is credited whether or not its licence asks for it, and the
    /// ones that state no terms say so on screen.
    ///
    /// Rounding an unstated licence up to a permissive one on an
    /// acknowledgements screen would be misleading exactly where a reader is
    /// looking for the truth.
    func testAcknowledgementsCreditEverythingAndStateUnknownTerms() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        let link = app.buttons["boffin.acknowledgements-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 20), "no acknowledgements link")
        link.tap()

        XCTAssertTrue(
            app.navigationBars["Acknowledgements"].waitForExistence(timeout: 10),
            "the acknowledgements screen did not open")

        // Scrolled to, not just queried. A List cell below the fold does not
        // exist in the accessibility tree, so asserting `.exists` on the last
        // few entries tests the screen height rather than the content.
        for source in ["ESM-2", "Mol*", "RCSB PDB", "UniProt", "SIFTS", "DSSP", "PLIP"] {
            var attempts = 0
            while !app.staticTexts[source].exists && attempts < 8 {
                app.swipeUp()
                attempts += 1
            }
            XCTAssertTrue(
                app.staticTexts[source].exists, "\(source) is not credited")
        }

        // The honest column. If this ever reads as a permissive licence, the
        // screen has started rounding up.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "None stated")
            ).count > 0,
            "no source is shown as having unstated terms")

        // By identifier rather than by label. `containing` matches elements
        // that CONTAIN a match, which is a different query from "this
        // element's own label contains", and on a leaf it can find nothing.
        var attempts = 0
        let researchUse = app.staticTexts["boffin.research-use-only"]
        while !researchUse.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(researchUse.exists, "the research-use statement is missing")
    }
}
