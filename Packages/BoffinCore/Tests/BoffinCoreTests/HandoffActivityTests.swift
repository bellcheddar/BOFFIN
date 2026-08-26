//  HandoffActivityTests.swift
//  BoffinCoreTests

import Foundation
import Testing

@testable import BoffinCore

@Suite("Handoff")
struct HandoffActivityTests {

    @Test("The activity type matches the one declared in Info.plist")
    func typeMatchesInfoPlist() {
        // Written out rather than referenced. A type absent from
        // NSUserActivityTypes is silently ignored: the activity is created,
        // becomeCurrent() succeeds, and nothing appears on the other device.
        #expect(HandoffActivity.type == "com.mdeller.boffin.analyse")
    }

    @Test("A normal sequence round-trips")
    func roundTrip() throws {
        let payload = try #require(
            HandoffActivity.payload(name: "CDK2_HUMAN", letters: "MENFQKVEKIGEGTYGVVYK"))
        let read = try #require(HandoffActivity.read(payload))
        #expect(read.name == "CDK2_HUMAN")
        #expect(read.letters == "MENFQKVEKIGEGTYGVVYK")
    }

    @Test("An oversized sequence is declined rather than truncated")
    func oversizedIsDeclined() {
        let huge = String(repeating: "A", count: HandoffActivity.maximumResidues + 1)
        // Declined, not shortened. Truncating would hand the other device a
        // fragment carrying the whole protein's name, and it would analyse and
        // report on the fragment as though it were the protein.
        #expect(HandoffActivity.payload(name: "huge", letters: huge) == nil)
        #expect(
            HandoffActivity.payload(
                name: "at the limit",
                letters: String(repeating: "A", count: HandoffActivity.maximumResidues)) != nil)
    }

    @Test("Empty and malformed payloads are refused")
    func refusesRubbish() {
        #expect(HandoffActivity.payload(name: "x", letters: "") == nil)
        #expect(HandoffActivity.read(nil) == nil)
        #expect(HandoffActivity.read([:]) == nil)
        #expect(HandoffActivity.read(["sequence": ""]) == nil)
        #expect(HandoffActivity.read(["sequence": 42]) == nil)
    }

    @Test("A payload with no name still continues, under a stated fallback")
    func nameIsOptional() throws {
        let read = try #require(HandoffActivity.read(["sequence": "MKV"]))
        #expect(read.name == "Continued sequence")
    }
}
