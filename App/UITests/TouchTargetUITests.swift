//  TouchTargetUITests.swift
//  BOFFINUITests
//
//  Every control a finger has to hit should be at least 44 points.
//
//  `Spacing.minimumTouchTarget` states that, cites the Human Interface
//  Guidelines, and had exactly one reference in the whole project: its own
//  declaration. A constant expressing an intention that nothing enforces is a
//  comment with a type.
//
//  This measures rather than assumes. It walks the controls on each tab and
//  reports any that fall short, so the fix can be aimed at the ones that need
//  it instead of applying a frame to everything and hoping the layouts survive.

import XCTest

final class TouchTargetUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The Human Interface Guidelines minimum, and the value the app already
    /// declares in `Spacing.minimumTouchTarget`.
    private let minimum: CGFloat = 44

    /// The frames of the navigation bars, tab bars and toolbars on screen.
    ///
    /// The system lays its own bars out and sizes the controls in them: an
    /// iPad tab bar item is 36 points tall and a navigation-bar glyph is 36
    /// inside a 44-point bar, with UIKit extending the hit region to the bar
    /// rather than growing the frame the accessibility tree publishes. Putting
    /// a 44-point frame on those fights the layout instead of helping it.
    ///
    /// Excluding them by geometry rather than by name matters. The first
    /// version of this listed "Sequence" as exempt, which would equally have
    /// exempted any button in the content area that happened to share the
    /// label -- an exemption that silently widens is the thing this test
    /// exists to catch.
    private func systemBarFrames(in app: XCUIApplication) -> [CGRect] {
        [app.navigationBars, app.tabBars, app.toolbars]
            .flatMap { $0.allElementsBoundByIndex }
            .filter { $0.exists }
            .map { $0.frame }
    }

    private func rounded(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func undersizedControls(in app: XCUIApplication) -> [(String, CGSize)] {
        let bars = systemBarFrames(in: app)
        var undersized: [(String, CGSize)] = []
        var seen: Set<String> = []
        for control in app.buttons.allElementsBoundByIndex {
            guard control.exists, control.isHittable else { continue }
            let label = control.identifier.isEmpty ? control.label : control.identifier
            guard !label.isEmpty else { continue }
            let frame = control.frame
            guard !bars.contains(where: { $0.contains(frame) }) else { continue }
            // iPadOS publishes each tab item twice; report a control once.
            guard seen.insert(label).inserted else { continue }
            let size = frame.size
            // Zero-sized elements are containers the accessibility tree
            // publishes rather than anything a finger meets.
            guard size.width > 0, size.height > 0 else { continue }
            // Not a lowered bar: the frames arrive through a coordinate
            // transform and a control laid out at exactly 44 points measures
            // 43.99999999999994. The tolerance is far below any real shortfall
            // -- a control genuinely half a point short still fails.
            let noise = 0.01
            if size.height < minimum - noise || size.width < minimum - noise {
                undersized.append((label, size))
            }
        }
        return undersized
    }

    func testControlsMeetTheMinimumTouchTarget() {
        let app = XCUIApplication()
        app.launchSkippingOnboarding()

        var report: [String] = []
        for tab in ["Order", "Fitness", "Family", "Boundary", "Structure"] {
            app.openTab(tab)
            for (label, size) in undersizedControls(in: app) {
                report.append(
                    "\(tab)/\(label): \(rounded(size.width))x\(rounded(size.height))")
            }
        }

        // Reported as a single failure listing everything, not one per control:
        // a wall of near-identical failures is harder to act on than a list.
        XCTAssertTrue(
            report.isEmpty,
            "controls below \(Int(minimum))pt: \(report.joined(separator: ", "))")
    }
}
