//  FamilyTabUITests.swift
//  BOFFINUITests

import XCTest

final class FamilyTabUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testUbiquitinShowsNoFamilyRatherThanAWrongOne() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Paste a sequence"].tap()
        app.buttons["Use the ubiquitin example"].tap()
        app.buttons["Analyse"].tap()
        XCTAssertTrue(
            app.staticTexts["76 residues \u{00B7} pasted"].waitForExistence(timeout: 15))

        app.tabBars.buttons["Family"].tap()
        // Ubiquitin is neither a kinase nor a GPCR. Saying so is the correct
        // answer; inventing a family would be worse than useless.
        XCTAssertTrue(
            app.staticTexts["No family motifs recognised"].waitForExistence(timeout: 10))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Family tab, no family"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
