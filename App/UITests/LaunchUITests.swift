//  LaunchUITests.swift
//  BOFFINUITests

import XCTest

final class LaunchUITests: XCTestCase {

    /// Phase 0 acceptance: the app launches on iPhone and iPad simulators.
    ///
    /// Two things this test learned the hard way, both on iPad.
    ///
    /// It used to assert that a `tabBars` element exists. A SwiftUI `TabView` on
    /// iPadOS 26 renders its tabs as a top-anchored strip, not as a UIKit tab
    /// bar, so that assertion was checking a presentation choice the app never
    /// makes rather than whether the app came up.
    ///
    /// It then asserted `isHittable` on the tab, which also failed, and not
    /// because anything was wrong: each tab is published as a Button CONTAINING
    /// an identical Button, so the outer one is covered by the inner one and
    /// reports itself unhittable. `app.buttons["Order"]` resolves to the outer.
    /// The fix is to stop asking about hit-testing and ask the question that
    /// matters: can you get to the tab and does its screen appear.
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()

        let order = app.buttons["Order"].firstMatch
        XCTAssertTrue(
            order.waitForExistence(timeout: 30),
            "the Order tab never appeared, so the app did not come up")

        // Every tab the app declares must be present, whatever the container
        // turns out to be on this idiom.
        for tab in ["Order", "Fitness", "Family", "Boundary", "Structure"] {
            XCTAssertTrue(
                app.buttons[tab].firstMatch.waitForExistence(timeout: 5),
                "the \(tab) tab is missing")
        }

        // Reachability, demonstrated rather than inferred: switch tabs and check
        // the destination's navigation title arrives.
        app.buttons["Family"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Family"].waitForExistence(timeout: 10),
            "tapping Family did not bring up the Family screen")

        app.buttons["Order"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Order"].waitForExistence(timeout: 10),
            "tapping Order did not bring back the Order screen")
    }
}

//  One way to reach a tab, because there turned out to be two wrong ones.
//
//  `app.tabBars.buttons["Family"]` works on iPhone and finds nothing on iPad: a
//  SwiftUI `TabView` on iPadOS 26 renders a top-anchored strip rather than a
//  UIKit tab bar. `app.buttons["Family"]` finds it on both and is not tappable
//  on iPad, because each tab is published as a Button containing an identical
//  Button and the query resolves to the covered outer one.
//
//  `.firstMatch` plus a wait handles both idioms, and the assertion is on the
//  destination arriving rather than on the tap appearing to work.

extension XCUIApplication {

    /// Switch to a tab and wait for its screen.
    func openTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = buttons[name].firstMatch
        XCTAssertTrue(
            tab.waitForExistence(timeout: 15), "the \(name) tab is missing",
            file: file, line: line)
        tab.tap()
        XCTAssertTrue(
            navigationBars[name].waitForExistence(timeout: 15),
            "tapping \(name) did not bring up its screen", file: file, line: line)
    }
}
