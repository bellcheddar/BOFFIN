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
        app.launchSkippingOnboarding()

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

    /// Launch past the one-time welcome sheet.
    ///
    /// Every UI test but `OnboardingUITests` drives a specific screen, and on a
    /// fresh install a sheet over the tabs fails all of them for a reason that
    /// has nothing to do with what they assert. That test is the one that
    /// launches without the argument, so this cannot quietly become "onboarding
    /// is never shown to anyone".
    func launchSkippingOnboarding() {
        launchArguments.append("-boffin.skip-onboarding")
        launch()
    }

    /// Bring an element into view before tapping it.
    ///
    /// The Structure tab has grown several panels (assemblies, symmetry,
    /// selection, figure export, interactions), so controls that used to sit
    /// on the first screen are now below the fold. XCUITest happily reports
    /// such an element as existing and then fails the tap with "Failed to not
    /// hittable", which reads as a broken control rather than a scrolled one.
    /// Scroll a screen until an element is reachable.
    ///
    /// Two traps, both hit here. Swiping the APP rather than the scroll view
    /// changes tab: a SwiftUI `TabView` treats a horizontal-ish swipe as
    /// navigation, and a test that drifted onto the Fitness tab reported
    /// "painting put the viewer into an error state", which is a true statement
    /// about a screen it should never have been looking at. And the structure
    /// viewer is a web view that swallows gestures aimed at it.
    ///
    /// So the swipe goes to the scroll view or nowhere. No `app.swipeUp()`
    /// fallback: doing nothing is recoverable, changing screen is not.
    func scrollTo(_ element: XCUIElement, attempts: Int = 8) {
        guard !element.isHittable else { return }
        let scroller = scrollViews.firstMatch
        guard scroller.exists else { return }
        for _ in 0..<attempts {
            scroller.swipeUp()
            if element.isHittable { return }
        }
    }

    /// Load the bundled structure and wait for the viewer to report it.
    ///
    /// Centralised because it is the first step of nine tests and it has failed
    /// on CI twice, on different tests each time, with "the structure never
    /// loaded". A bare tap-then-wait cannot say WHY: the tap may not have
    /// landed, the bridge may have errored, or the app may have released the
    /// structure under memory pressure, and all three look identical from a
    /// timed-out wait.
    ///
    /// So the failure carries what is actually on screen. The same technique
    /// found a test that had silently drifted onto the Fitness tab.
    func loadBundledStructure(
        atomCount: Int = 660, file: StaticString = #filePath, line: UInt = #line
    ) {
        let load = buttons["boffin.load-structure"]
        XCTAssertTrue(
            load.waitForExistence(timeout: 30), "no load control", file: file, line: line)
        scrollTo(load)
        forceTap(load)

        let loaded = staticTexts["\(atomCount.formatted()) atoms"]
        if loaded.waitForExistence(timeout: StructureTabUITests.structureLoad) { return }

        // Tap once more before giving up. A tap that does not register is the
        // cheapest of the three explanations to rule out, and retrying it does
        // not mask the other two: they will still fail, and now with a report.
        forceTap(load)
        if loaded.waitForExistence(timeout: 60) { return }

        let visible = staticTexts.allElementsBoundByIndex
            .prefix(20).map { $0.label }.filter { !$0.isEmpty }.joined(separator: " | ")
        XCTFail(
            "the structure never loaded after two taps. On screen: \(visible)",
            file: file, line: line)
    }

    /// Scroll back until an element reappears.
    ///
    /// A SwiftUI `ScrollView` drops off-screen content out of the accessibility
    /// tree entirely, so something above the fold reads as missing rather than
    /// as scrolled away.
    func scrollBackTo(_ element: XCUIElement, attempts: Int = 8) {
        let scroller = scrollViews.firstMatch
        guard scroller.exists else { return }
        for _ in 0..<attempts where !element.exists {
            scroller.swipeDown()
        }
    }

    /// Tap an element whether or not it reports itself hittable.
    ///
    /// `isHittable` is false for anything obscured, including a control merely
    /// overlapped by the tab bar, and the resulting "Failed to not hittable"
    /// reads as a broken control. A coordinate tap addresses the element's own
    /// centre and is the honest way to say "press this".
    func forceTap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Switch to a tab and wait for its screen.
    /// Tap a button once it is actually there.
    ///
    /// `app.tapButton("X")` fails the instant X is absent, and a sheet
    /// that is still animating in is absent. Twenty-three call sites tapped
    /// blind, and the one that failed most is the pair
    /// "Paste a sequence" then "Use the CDK2 example": the second tap lands
    /// while the sheet the first opened is still on its way. Under load that
    /// reads as "No matches found for Elements matching predicate", which
    /// looks like a missing button rather than an early tap.
    ///
    /// CI passes `-retry-tests-on-failure`, so these were being masked rather
    /// than fixed. A test that needs a retry is a test that will eventually
    /// fail both attempts.
    func tapButton(
        _ label: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let button = buttons[label]
        guard button.waitForExistence(timeout: timeout) else {
            let visible = buttons.allElementsBoundByIndex
                .filter(\.exists)
                .prefix(12)
                .map { $0.label.isEmpty ? $0.identifier : $0.label }
            XCTFail(
                "no button \"\(label)\" after \(Int(timeout))s; visible: \(visible)",
                file: file, line: line)
            return
        }
        button.tap()
    }

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
