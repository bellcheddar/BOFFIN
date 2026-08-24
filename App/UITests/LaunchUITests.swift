//  LaunchUITests.swift
//  BOFFINUITests

import XCTest

final class LaunchUITests: XCTestCase {

    /// Phase 0 acceptance: the app launches on iPhone and iPad simulators.
    ///
    /// Originally asserted on the placeholder wordmark. Phase 1 replaced that
    /// screen with the tab structure, so the assertion moved to the tab bar,
    /// which is the thing that actually means "the app came up".
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 10),
            "the tab bar did not appear")
        XCTAssertTrue(app.buttons["Order"].exists, "the Order tab is missing")
    }
}
