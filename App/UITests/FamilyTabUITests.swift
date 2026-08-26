//  FamilyTabUITests.swift
//  BOFFINUITests

import XCTest

final class FamilyTabUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testUbiquitinShowsNoFamilyRatherThanAWrongOne() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.tapButton("Paste a sequence")
        app.tapButton("Use the ubiquitin example")
        app.tapButton("Analyse")
        XCTAssertTrue(
            app.staticTexts["76 residues \u{00B7} pasted"].waitForExistence(timeout: 15))

        app.openTab("Family")
        // Ubiquitin is neither a kinase nor a GPCR. Saying so is the correct
        // answer; inventing a family would be worse than useless.
        XCTAssertTrue(
            app.staticTexts["No family motifs recognised"].waitForExistence(timeout: 10))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Family tab, no family"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The build plan's Phase 5 acceptance, checked through the interface a
    /// user actually sees rather than only at the data layer: "the DFG, HRD,
    /// gatekeeper and hinge annotate at the correct KLIFS positions".
    ///
    /// Every expected residue number here is CDK2's published numbering, and
    /// was taken from KLIFS's own mapping for 1HCK rather than from memory.
    func testCDK2AnnotatesItsPocketLandmarksByName() throws {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()
        app.tapButton("Paste a sequence")
        let cdk2Button = app.buttons["Use the CDK2 example"]
        XCTAssertTrue(cdk2Button.waitForExistence(timeout: 10), "no CDK2 example button")
        cdk2Button.tap()
        app.tapButton("Analyse")
        // Not "pasted": the example carries a `>sp|P24941|CDK2_HUMAN` header,
        // so the parser recognises it as a UniProt record and says so. That is
        // the parser working, and this assertion pins it.
        let header = app.staticTexts["298 residues \u{00B7} UniProt P24941"]
        XCTAssertTrue(header.waitForExistence(timeout: 20), "sequence header did not appear")

        app.openTab("Family")

        // Motifs first: these need no model and no downloaded asset.
        XCTAssertTrue(
            app.staticTexts["Protein kinase"].waitForExistence(timeout: 15),
            "CDK2 was not recognised as a kinase")
        XCTAssertTrue(app.staticTexts["HRD"].exists, "the HRD motif was not annotated")
        XCTAssertTrue(app.staticTexts["DFG"].exists, "the DFG motif was not annotated")

        // Then the named KLIFS landmarks, which is the part a bare position
        // number does not deliver.
        XCTAssertTrue(
            app.staticTexts["Gatekeeper"].waitForExistence(timeout: 20),
            "the gatekeeper was not named")
        XCTAssertTrue(app.staticTexts["F80"].exists, "the gatekeeper is CDK2 F80")
        XCTAssertTrue(app.staticTexts["E81 to L83"].exists, "the hinge is CDK2 E81 to L83")
        XCTAssertTrue(app.staticTexts["D145 to G147"].exists, "the DFG is CDK2 D145 to G147")
        XCTAssertTrue(app.staticTexts["K33"].exists, "the beta-3 lysine is CDK2 K33")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Family tab, CDK2 pocket landmarks"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
