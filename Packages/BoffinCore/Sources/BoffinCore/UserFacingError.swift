//  UserFacingError.swift
//  BoffinCore
//
//  Turning a thrown error into something a person can act on.
//
//  Five places in the app showed the user `String(describing: error)`, which
//  for a Core ML failure reads:
//
//      Error Domain=com.apple.CoreML Code=0 "Failed to build the model
//      execution plan using a model architecture file '/var/.../model.mil'
//      with error code: -7."
//
//  That is a diagnostic, and a good one, but it is not a message. A reader
//  cannot tell from it whether they did something wrong, whether it will work
//  if they try again, or what to do next, and the honest three-way split
//  between those is the only thing they actually want.
//
//  So every failure the user sees is now three fields:
//
//  - `summary`, one sentence naming what did not happen, in terms of the thing
//    the user asked for rather than the layer that threw;
//  - `recovery`, what they can do, or nil when there genuinely is nothing, in
//    which case saying nothing beats inventing "please try again";
//  - `detail`, the raw text, kept verbatim and shown behind a disclosure.
//
//  The raw text is KEPT, not discarded. A bug report with the Core ML error
//  code in it is worth more than one that says "analysis failed", and a
//  scientist reading their own stack trace is a normal Tuesday. It is demoted,
//  not hidden.

import Foundation

/// A failure, expressed for the person who has to read it.
public struct UserFacingError: Sendable, Equatable, Hashable {
    /// One sentence: what did not happen.
    public let summary: String

    /// What the reader can do about it, or `nil` when nothing will help.
    ///
    /// Optional on purpose. "Please try again" attached to a permanent failure
    /// is worse than silence: it sends someone to repeat an action that cannot
    /// succeed, and it costs the app the reader's trust the second time.
    public let recovery: String?

    /// The original error text, verbatim, for the disclosure and for bug
    /// reports. Never the headline.
    public let detail: String

    public init(summary: String, recovery: String? = nil, detail: String) {
        self.summary = summary
        self.recovery = recovery
        self.detail = detail
    }

    /// Classify a thrown error.
    ///
    /// - Parameters:
    ///   - error: what was thrown.
    ///   - action: the user's action, as a gerund phrase that completes
    ///     "BOFFIN could not finish ...". "searching for relatives", not
    ///     "HomologIndex.search".
    public init(_ error: any Error, whileDoing action: String) {
        let raw = String(describing: error)

        // Cancellation is not a failure and must never be reported as one. A
        // user who changed the sequence mid-scan did exactly what the app
        // invited them to do; telling them it went wrong is the app calling
        // its own affordance a mistake.
        if error is CancellationError {
            self.init(
                summary: "\(action.capitalisedFirst) was cancelled.",
                recovery: nil, detail: raw)
            return
        }

        if let url = error as? URLError {
            self.init(url: url, action: action, raw: raw)
            return
        }

        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile {
            self.init(
                summary: "BOFFIN could not finish \(action): a file it needed is missing.",
                recovery: "If this is a downloadable asset it may not have arrived yet.",
                detail: raw)
            return
        }

        // Anything else. The summary still names the user's action rather than
        // the failing layer, because "analysis failed" tells them which button
        // not to press again and "MLModelErrorDomain" does not.
        self.init(
            summary: "BOFFIN could not finish \(action).",
            recovery: nil, detail: raw)
    }

    private init(url: URLError, action: String, raw: String) {
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost:
            self.init(
                summary: "BOFFIN could not finish \(action) because there is no connection.",
                // The honest and reassuring half in one line: this is the only
                // part of the app that needs the network at all.
                recovery: "Everything except fetching structures works offline.",
                detail: raw)
        case .timedOut:
            self.init(
                summary: "\(action.capitalisedFirst) timed out.",
                recovery: "The server did not answer. Trying again usually works.",
                detail: raw)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            self.init(
                summary: "BOFFIN could not reach the server while \(action).",
                recovery: "The archive may be down, or the connection may be filtered.",
                detail: raw)
        case .fileDoesNotExist, .badServerResponse, .resourceUnavailable:
            self.init(
                summary: "The server had nothing for that request.",
                recovery: "Check the identifier: a structure that does not exist "
                    + "and one that has been withdrawn look the same from here.",
                detail: raw)
        case .cancelled:
            self.init(
                summary: "\(action.capitalisedFirst) was cancelled.", recovery: nil, detail: raw)
        default:
            self.init(
                summary: "BOFFIN could not finish \(action) because the network failed.",
                recovery: "Everything except fetching structures works offline.",
                detail: raw)
        }
    }
}

extension String {
    /// Capitalise the first character only, leaving the rest alone.
    ///
    /// Not `capitalized`, which title-cases every word and turns "searching for
    /// relatives" into "Searching For Relatives", and not `uppercased()` on a
    /// prefix, which is wrong for any character outside ASCII.
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
