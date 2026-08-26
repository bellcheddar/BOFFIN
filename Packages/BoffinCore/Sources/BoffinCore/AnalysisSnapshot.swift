//  AnalysisSnapshot.swift
//  BoffinCore
//
//  The last analysis, small enough for a widget to read.
//
//  A widget gets a few tens of megabytes and a few seconds, so it cannot run
//  the model, load a 67 MB backbone, or parse a structure. What it can do is
//  read a handful of numbers the app has already computed and left in the
//  shared container. Everything here is either a string or a Double for that
//  reason.

import Foundation

public struct AnalysisSnapshot: Codable, Sendable, Hashable {

    public let name: String
    public let residueCount: Int
    /// Fraction of residues predicted disordered, 0 to 1.
    public let disorderedFraction: Double
    /// Fraction predicted helix and strand, for the secondary-structure split.
    public let helixFraction: Double
    public let strandFraction: Double
    /// The family called, when one was, and how confident the call was.
    public let familyName: String?
    public let familyConfidence: Double?
    public let analysedAt: Date

    public init(
        name: String, residueCount: Int, disorderedFraction: Double,
        helixFraction: Double, strandFraction: Double,
        familyName: String?, familyConfidence: Double?, analysedAt: Date
    ) {
        self.name = name
        self.residueCount = residueCount
        self.disorderedFraction = disorderedFraction
        self.helixFraction = helixFraction
        self.strandFraction = strandFraction
        self.familyName = familyName
        self.familyConfidence = familyConfidence
        self.analysedAt = analysedAt
    }
}

extension SharedInbox {

    static let snapshotName = "last-analysis.json"

    private static var snapshotURL: URL? {
        containerURL?.appending(path: snapshotName)
    }

    /// Record the last analysis for the widget to show.
    ///
    /// Failures are ignored on purpose. A widget that cannot be updated is a
    /// stale widget; an analysis that fails because a widget could not be
    /// updated would be absurd.
    public static func writeSnapshot(_ snapshot: AnalysisSnapshot) {
        guard let containerURL, let snapshotURL else { return }
        try? FileManager.default.createDirectory(
            at: containerURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    /// The last analysis, if the app has done one.
    ///
    /// NOT consumed, unlike the shared sequence: the widget reads this
    /// repeatedly and clearing it would blank the widget the first time it
    /// refreshed.
    public static func readSnapshot() -> AnalysisSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL)
        else { return nil }
        return try? JSONDecoder().decode(AnalysisSnapshot.self, from: data)
    }
}
