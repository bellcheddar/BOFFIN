//  FitnessTabUITests.swift
//  BOFFINUITests
//
//  Phase 4 acceptance, driven the way a user would.

import XCTest

final class FitnessTabUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func loadUbiquitin(_ app: XCUIApplication) {
        app.buttons["Paste a sequence"].tap()
        app.buttons["Use the ubiquitin example"].tap()
        app.buttons["Analyse"].tap()
        XCTAssertTrue(
            app.staticTexts["76 residues \u{00B7} pasted"].waitForExistence(timeout: 15))
    }

    func testFastPreviewProducesAHeatmapAndLogo() throws {
        let app = XCUIApplication()
        app.launch()
        loadUbiquitin(app)

        app.buttons["Fitness"].tap()
        let fast = app.buttons["Fast preview"]
        XCTAssertTrue(fast.waitForExistence(timeout: 10), "scan controls did not appear")
        fast.tap()

        // The fast mode is a single forward pass, so this should be quick.
        let heatmap = app.descendants(matching: .any)
            .matching(identifier: "boffin.llr-heatmap").firstMatch
        XCTAssertTrue(heatmap.waitForExistence(timeout: 60), "heatmap did not render")

        let logo = app.descendants(matching: .any)
            .matching(identifier: "boffin.sequence-logo").firstMatch
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "sequence logo did not render")

        // The mode must be stated: two matrices of identical shape mean
        // different things and a reader cannot tell them apart by looking.
        XCTAssertTrue(app.staticTexts["Fast preview"].exists, "scoring mode not shown")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Fitness tab, fast preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFitnessTabTellsYouToLoadASequenceFirst() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Fitness"].tap()
        XCTAssertTrue(app.staticTexts["No sequence"].waitForExistence(timeout: 10))
    }
}
