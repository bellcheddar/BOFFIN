//  NeuralEngineStatusTests.swift
//  BoffinUITests

import Testing

@testable import BoffinUI

@Suite("Neural Engine status")
struct NeuralEngineStatusTests {

    @Test("The residency figure is the measured one, not a round number")
    func residencyIsMeasured() {
        // 746 of 755, from MLComputePlan on 2026-08-24. Asserted so that a
        // tidy-up to "99%" has to be a deliberate act rather than a slip: the
        // whole point of showing it is that it was measured.
        #expect(NeuralEngineStatus.scheduledOnANE == 746)
        #expect(NeuralEngineStatus.totalOperations == 755)
        #expect(abs(NeuralEngineStatus.scheduledFraction - 0.988) < 0.001)
    }

    @Test("Nothing is claimed before a pass has run")
    func silentBeforeFirstPass() {
        // An app showing "0 passes · last 0 ms" is stating a measurement it
        // has not made.
        #expect(NeuralEngineStatus().detail == nil)
        #expect(NeuralEngineStatus(activity: .embedding).detail == nil)
    }

    @Test("The detail reads as a count and a duration once there is one")
    func detailAfterPasses() {
        #expect(NeuralEngineStatus(passes: 1).detail == "1 pass")
        #expect(NeuralEngineStatus(passes: 4).detail == "4 passes")
        let quick = NeuralEngineStatus(passes: 2, lastPassSeconds: 0.031)
        #expect(quick.detail == "2 passes · last 31 ms")
        // Seconds past a second, because "9350 ms" is not how anyone reads a
        // number they are waiting through.
        let slow = NeuralEngineStatus(passes: 3, lastPassSeconds: 6.9)
        #expect(slow.detail == "3 passes · last 6.9 s")
    }

    @Test("Idle is the only inactive state")
    func activityFlags() {
        #expect(!NeuralEngineStatus.Activity.idle.isActive)
        for activity: NeuralEngineStatus.Activity in [
            .embedding, .heads, .scanning(fraction: 0),
        ] {
            #expect(activity.isActive)
        }
    }

    @Test("Every activity says something in the user's terms")
    func labelsAreHuman() {
        for activity: NeuralEngineStatus.Activity in [
            .idle, .embedding, .heads, .scanning(fraction: 0.5),
        ] {
            // Not "inference", not "forward pass", not "ANE". The bar is for
            // someone watching the app work, not for us.
            #expect(!activity.label.isEmpty)
            #expect(!activity.label.lowercased().contains("inference"))
        }
    }
}
