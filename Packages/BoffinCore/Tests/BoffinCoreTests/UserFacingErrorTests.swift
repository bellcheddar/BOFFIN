//  UserFacingErrorTests.swift
//  BoffinCoreTests

import Foundation
import Testing

@testable import BoffinCore

@Suite("User-facing errors")
struct UserFacingErrorTests {

    @Test("The raw error text is kept, never discarded")
    func rawTextSurvives() {
        // The whole design rests on demoting the diagnostic rather than losing
        // it: a bug report carrying the Core ML error code is worth far more
        // than one saying "analysis failed". If this ever stops holding, the
        // technical disclosure has nothing to disclose.
        struct Odd: Error, CustomStringConvertible {
            var description: String { "MLModelErrorDomain code -7 at /var/tmp/model.mil" }
        }
        let failure = UserFacingError(Odd(), whileDoing: "analysing the sequence")
        #expect(failure.detail.contains("MLModelErrorDomain"))
        #expect(failure.detail.contains("-7"))
        // ... and is not the headline.
        #expect(!failure.summary.contains("MLModelErrorDomain"))
    }

    @Test("Cancellation is never reported as a failure")
    func cancellationIsNotAFailure() {
        // A user who changed the sequence mid-scan did exactly what the app
        // invited them to do. Telling them it went wrong is the app calling
        // its own affordance a mistake, and it trains people to distrust a
        // warning that is usually real.
        let failure = UserFacingError(CancellationError(), whileDoing: "scanning mutations")
        #expect(failure.summary == "Scanning mutations was cancelled.")
        #expect(failure.recovery == nil, "there is nothing to recover from")
        #expect(!failure.summary.lowercased().contains("could not"))
        #expect(!failure.summary.lowercased().contains("failed"))
    }

    @Test("Being offline says what still works")
    func offlineNamesWhatStillWorks() {
        // This is the one message that can turn a scare into a shrug. BOFFIN's
        // entire premise is that it works with no network, so a connection
        // error is a statement about one optional feature rather than about
        // the app.
        let failure = UserFacingError(
            URLError(.notConnectedToInternet), whileDoing: "fetching the structure")
        #expect(failure.summary.contains("no connection"))
        #expect(failure.recovery?.contains("offline") == true)
    }

    @Test("A missing structure does not blame the connection")
    func missingStructureIsNotANetworkProblem() {
        // 404 and "your wifi is off" are the same colour of red to a user and
        // completely different problems. Confusing them sends someone to check
        // their router over a typo in a PDB ID.
        let failure = UserFacingError(
            URLError(.fileDoesNotExist), whileDoing: "fetching the structure")
        #expect(failure.summary.contains("nothing for that request"))
        #expect(failure.recovery?.contains("identifier") == true)
        #expect(failure.recovery?.lowercased().contains("offline") != true)
    }

    @Test("Recovery advice is absent rather than invented")
    func noAdviceWhenNoneWouldHelp() {
        // "Please try again" on a permanent failure is worse than silence: it
        // sends someone to repeat an action that cannot succeed, and the app
        // spends its credibility to do it.
        struct Permanent: Error {}
        let failure = UserFacingError(Permanent(), whileDoing: "loading the heads")
        #expect(failure.recovery == nil)
        #expect(failure.summary == "BOFFIN could not finish loading the heads.")
    }

    @Test("Timing out suggests retrying, because retrying works")
    func timeoutSuggestsRetry() {
        let failure = UserFacingError(URLError(.timedOut), whileDoing: "fetching the structure")
        #expect(failure.recovery?.contains("again") == true)
    }

    @Test("Only the first character is capitalised")
    func capitalisationDoesNotTitleCase() {
        // `String.capitalized` would render "scanning mutations was cancelled"
        // as "Scanning Mutations Was Cancelled", which reads like a headline in
        // a local newspaper rather than a sentence.
        #expect("searching for relatives".capitalisedFirst == "Searching for relatives")
        // Leaves an already-capitalised string alone, and does not trap on empty.
        #expect("BOFFIN could not".capitalisedFirst == "BOFFIN could not")
        #expect("".capitalisedFirst == "")
    }
}
