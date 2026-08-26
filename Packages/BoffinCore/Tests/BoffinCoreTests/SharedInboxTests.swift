//  SharedInboxTests.swift
//  BoffinCoreTests
//
//  The hand-off the share extension depends on.
//
//  `containerURL` is nil without the App Group entitlement, which a unit test
//  bundle does not have, so the tests that need a real container skip rather
//  than fail. What can be tested anywhere is tested anywhere: the identifiers
//  both sides must agree on, and the consume-once behaviour.

import Foundation
import Testing

@testable import BoffinCore

@Suite("Shared inbox")
struct SharedInboxTests {

    @Test("The app group and URL match what the extension and Info.plist use")
    func identifiersAgree() {
        // Written out rather than referenced, deliberately. These strings also
        // appear in two entitlements files and the app's Info.plist, and
        // nothing else compares them: a rename that misses one makes
        // containerURL nil, which reads as "nothing was shared" rather than as
        // a configuration error.
        #expect(SharedInbox.appGroup == "group.com.mdeller.boffin")
        #expect(SharedInbox.openURL.scheme == "boffin")
        #expect(SharedInbox.openURL.host == "shared")
    }

    @Test(
        "Taking clears, so a sequence is not re-read on every launch",
        .enabled(if: SharedInbox.containerURL != nil))
    func takeConsumes() {
        #expect(SharedInbox.write("MQIFVKTLTGKTITLEVE"))
        #expect(SharedInbox.take() == "MQIFVKTLTGKTITLEVE")
        // The second take must be empty: left in place, the same sequence
        // would reappear over whatever the user was working on.
        #expect(SharedInbox.take() == nil)
    }

    @Test(
        "Empty text is not treated as a shared sequence",
        .enabled(if: SharedInbox.containerURL != nil))
    func emptyIsNothing() {
        SharedInbox.write("")
        #expect(SharedInbox.take() == nil)
    }
}

@Suite("Analysis snapshot")
struct AnalysisSnapshotTests {

    private var example: AnalysisSnapshot {
        AnalysisSnapshot(
            name: "CDK2_HUMAN", residueCount: 298, disorderedFraction: 0.11,
            helixFraction: 0.34, strandFraction: 0.19,
            familyName: "PF00069", familyConfidence: 0.98, analysedAt: Date())
    }

    @Test(
        "The snapshot survives the round trip the widget reads it through",
        .enabled(if: SharedInbox.containerURL != nil))
    func roundTrip() throws {
        SharedInbox.writeSnapshot(example)
        let read = try #require(SharedInbox.readSnapshot())
        #expect(read.name == "CDK2_HUMAN")
        #expect(read.residueCount == 298)
        #expect(abs(read.disorderedFraction - 0.11) < 1e-9)
        #expect(read.familyName == "PF00069")
    }

    @Test(
        "Reading does NOT consume, unlike the shared sequence",
        .enabled(if: SharedInbox.containerURL != nil))
    func readIsNotDestructive() {
        SharedInbox.writeSnapshot(example)
        #expect(SharedInbox.readSnapshot() != nil)
        // The widget reads this on every refresh. Consuming it, as `take()`
        // does for a shared sequence, would blank the widget the first time
        // iOS refreshed it.
        #expect(SharedInbox.readSnapshot() != nil)
    }

    @Test("The two shared files do not collide")
    func distinctFiles() {
        // Both live in the same container. If they shared a name, analysing a
        // sequence would look to the app like someone had shared one, and it
        // would try to parse JSON as FASTA.
        #expect(SharedInbox.fileName != SharedInbox.snapshotName)
    }
}
