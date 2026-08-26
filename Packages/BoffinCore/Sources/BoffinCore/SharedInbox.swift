//  SharedInbox.swift
//  BoffinCore
//
//  The hand-off point between the share extension and the app.
//
//  In BoffinCore because both the app and the extension need it and BoffinCore
//  is the only module that depends on nothing. A separate module for one file
//  would be a module for the sake of the diagram.
//
//  A file in an App Group container rather than a URL parameter. A URL carries
//  a 300-residue sequence and does not carry a multi-record FASTA, and the
//  failure mode is silent truncation: the app would analyse the first N
//  residues and report on them as though they were the whole protein.

import Foundation

public enum SharedInbox {

    /// The App Group both the app and its extensions are members of.
    ///
    /// **Must match the App Groups capability on both bundle IDs.** A mismatch
    /// makes `containerURL` return nil, which reads as "nothing was shared"
    /// rather than as a configuration error, so the write is silently dropped
    /// and the app opens with an empty Order tab.
    public static let appGroup = "group.com.mdeller.boffin"

    /// The URL the extension opens to bring the app forward.
    ///
    /// Built from components rather than force-unwrapping a string literal.
    /// The literal is a constant that cannot fail today, but the project bans
    /// force unwraps precisely so that nobody has to judge which ones are safe.
    public static let openURL: URL = {
        var components = URLComponents()
        components.scheme = "boffin"
        components.host = "shared"
        // The fallback is unreachable with the fixed components above, and is
        // here so the type is URL rather than URL? for every caller.
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    static let fileName = "shared-sequence.txt"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var fileURL: URL? {
        containerURL?.appending(path: fileName)
    }

    /// Store text for the app to pick up. Returns whether it was stored.
    @discardableResult
    public static func write(_ text: String) -> Bool {
        guard let containerURL, let fileURL else { return false }
        do {
            // Created if absent. On a device with the App Group entitlement
            // the system has already made it, but `containerURL` returns a
            // path on macOS whether or not anything exists there, so without
            // this the write fails and the extension reports success having
            // stored nothing.
            try FileManager.default.createDirectory(
                at: containerURL, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Take the shared text, if any, and clear it.
    ///
    /// Consuming rather than reading: left in place, the same sequence would
    /// reappear every time the app was opened by any route, overwriting
    /// whatever the user was working on.
    public static func take() -> String? {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        return text.isEmpty ? nil : text
    }
}
