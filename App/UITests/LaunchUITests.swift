//  LaunchUITests.swift
//  BOFFINUITests

import XCTest

final class LaunchUITests: XCTestCase {

    /// Phase 0 acceptance: the app launches on iPhone and iPad simulators.
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["BOFFIN"].waitForExistence(timeout: 10))
    }
}
