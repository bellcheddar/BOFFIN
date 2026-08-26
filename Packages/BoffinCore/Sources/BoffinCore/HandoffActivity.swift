//  HandoffActivity.swift
//  BoffinCore
//
//  Continuing an analysis on another device.
//
//  Handoff carries the SEQUENCE, not the results. The results are a few
//  hundred kilobytes of per-residue tracks and Handoff's payload is meant to
//  stay within a few kilobytes; more to the point, the receiving device can
//  recompute them in seconds from the sequence and would otherwise be showing
//  numbers it had not produced.

import Foundation

public enum HandoffActivity {

    /// Must also appear in the app's `NSUserActivityTypes`.
    ///
    /// A type not listed there is silently ignored by the system: the activity
    /// is created, `becomeCurrent()` succeeds, and nothing ever appears on the
    /// other device.
    public static let type = "com.mdeller.boffin.analyse"

    public static let sequenceKey = "sequence"
    public static let nameKey = "name"

    /// The longest sequence worth putting in a Handoff payload.
    ///
    /// Apple's guidance is to keep the userInfo small, and a sequence beyond
    /// this is a multi-domain protein or a concatenated file rather than
    /// something someone is reading on a phone. Truncating would be worse than
    /// declining: the other device would analyse a fragment and label it with
    /// the whole protein's name.
    public static let maximumResidues = 5000

    public static func payload(name: String, letters: String) -> [String: String]? {
        guard !letters.isEmpty, letters.count <= maximumResidues else { return nil }
        return [sequenceKey: letters, nameKey: name]
    }

    /// Read a payload back, rejecting anything that is not a usable sequence.
    public static func read(_ userInfo: [AnyHashable: Any]?) -> (name: String, letters: String)? {
        guard let letters = userInfo?[sequenceKey] as? String, !letters.isEmpty
        else { return nil }
        let name = userInfo?[nameKey] as? String ?? "Continued sequence"
        return (name, letters)
    }
}
