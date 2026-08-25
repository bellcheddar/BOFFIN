//  ConstructSolver.swift
//  BoffinCore
//
//  Phase 6's core: proposing expression constructs by choosing where to cut.
//
//  Why this lives in BoffinCore and knows nothing about models
//  -----------------------------------------------------------
//  The inputs it needs come from three modules that cannot see each other:
//  motifs from BoffinCore, transmembrane spans from BoffinML, observed
//  constructs from BoffinData. The dependency rule forbids reaching upward, and
//  the rule is right here rather than inconvenient: the solver does not reason
//  about topology heads or SIFTS, it reasons about REGIONS THAT MUST NOT BE CUT
//  and about where other people have successfully cut before. The app adapts its
//  types into those two ideas.
//
//  Hard constraints are enforced, not scored
//  -----------------------------------------
//  The build plan is explicit: "never truncate through a canonical motif, a
//  predicted TM span, a disulfide pair or a domain core. These are enforced by
//  the solver, not suggested." A weighted penalty would let a construct that
//  bisects the DFG motif win on the strength of everything else about it, and
//  that construct is not a compromise, it is dead protein.

import Foundation

/// A region a construct boundary must not fall inside.
public struct ConstructConstraint: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case motif
        case transmembrane
        case signalPeptide
        case disulfide
        case structuredCore

        /// How the refusal reads when this constraint blocks a cut.
        public var reason: String {
            switch self {
            case .motif: "a canonical motif"
            case .transmembrane: "a predicted transmembrane span"
            case .signalPeptide: "the signal peptide"
            case .disulfide: "a disulfide pair"
            case .structuredCore: "a structured region"
            }
        }
    }

    public let kind: Kind
    /// Zero-based, inclusive.
    public let range: ClosedRange<Int>
    public let label: String

    public init(kind: Kind, range: ClosedRange<Int>, label: String) {
        self.kind = kind
        self.range = range
        self.label = label
    }
}

/// One proposed construct.
public struct ConstructProposal: Sendable, Hashable, Identifiable {
    /// Zero-based, inclusive, in the coordinates of the input sequence.
    public let range: ClosedRange<Int>
    /// Why this one, in the order the reasons were applied.
    public let rationale: [String]
    /// Higher is better. Comparable only within one call.
    public let score: Double
    /// How many PDB entries in the precedent set have comparable boundaries.
    public let precedentCount: Int

    public var id: String { "\(range.lowerBound)-\(range.upperBound)" }
    public var length: Int { range.count }
    /// One-based, the way a construct is written on a tube.
    public var description: String {
        "\(range.lowerBound + 1) to \(range.upperBound + 1)"
    }

    public init(
        range: ClosedRange<Int>, rationale: [String], score: Double, precedentCount: Int
    ) {
        self.range = range
        self.rationale = rationale
        self.score = score
        self.precedentCount = precedentCount
    }
}

/// What the solver decided.
public enum ConstructSolverResult: Sendable, Hashable {
    case proposals([ConstructProposal])
    /// No construct is worth proposing, and why.
    ///
    /// A separate case rather than an empty array. An empty list reads as "the
    /// solver found nothing", which invites the user to try again; a refusal
    /// with a reason is a finding.
    case declined(String)

    public var proposals: [ConstructProposal] {
        if case .proposals(let list) = self { return list }
        return []
    }
}

public enum ConstructSolver {

    /// Below this fraction of ordered residues, there is no construct to make.
    ///
    /// An intrinsically disordered protein has no domain to truncate to, and a
    /// solver that proposes boundaries anyway is inventing a fold. Alpha
    /// synuclein is the fixture this exists for.
    public static let minimumOrderedFraction = 0.25

    /// Constructs shorter than this are not worth expressing.
    public static let minimumLength = 40

    /// How far a proposal's boundary may sit from a deposited one and still
    /// count as precedent.
    ///
    /// Ten residues is a judgement, and it is the one place in this file where
    /// a number was chosen rather than derived, so it is surfaced as a parameter
    /// and stated in the rationale rather than buried.
    public static let precedentTolerance = 10

    /// Propose truncations, best first.
    ///
    /// - Parameters:
    ///   - residueCount: length of the sequence.
    ///   - disordered: per-residue disorder calls, or empty when no prediction
    ///     is available. EMPTY IS NOT ALL-ORDERED: without a disorder track the
    ///     solver has nothing to trim towards and says so.
    ///   - constraints: regions no boundary may fall inside.
    ///   - precedent: observed ranges from deposited structures of homologues,
    ///     in the coordinates of this sequence.
    ///   - limit: how many proposals to return.
    /// - Returns: ranked proposals, or a refusal with the reason for it.
    public static func propose(
        residueCount: Int,
        disordered: [Bool],
        constraints: [ConstructConstraint],
        precedent: [ClosedRange<Int>] = [],
        limit: Int = 5
    ) -> ConstructSolverResult {
        guard residueCount >= minimumLength else {
            return .declined(
                "This sequence is \(residueCount) residues, shorter than the "
                    + "\(minimumLength) a construct is worth making.")
        }
        guard disordered.count == residueCount else {
            return .declined(
                "No disorder prediction is available for this sequence, and "
                    + "trimming without one would be guessing where the domain ends.")
        }

        let orderedFraction =
            Double(disordered.count { !$0 }) / Double(residueCount)
        guard orderedFraction >= minimumOrderedFraction else {
            return .declined(
                String(
                    format:
                        "Only %.0f%% of this sequence is predicted ordered. There is no "
                        + "domain here to truncate to, so proposing boundaries would be "
                        + "inventing one.", orderedFraction * 100))
        }

        let candidates = boundaryCandidates(
            residueCount: residueCount, disordered: disordered,
            constraints: constraints, precedent: precedent)

        var proposals: [ConstructProposal] = []
        for start in candidates.starts {
            for end in candidates.ends where end - start + 1 >= minimumLength {
                let range = start...end
                guard !violates(range, constraints: constraints) else { continue }
                guard covers(range, constraints: constraints) else { continue }
                proposals.append(
                    evaluate(
                        range, residueCount: residueCount, disordered: disordered,
                        constraints: constraints, precedent: precedent))
            }
        }

        guard !proposals.isEmpty else {
            return .declined(
                "Every truncation that keeps the annotated regions intact is either "
                    + "shorter than \(minimumLength) residues or cuts through one of "
                    + "them.")
        }

        let ranked =
            proposals
            .sorted { ($0.score, -$0.length) > ($1.score, -$1.length) }
            .prefix(limit)
        return .proposals(Array(ranked))
    }

    // MARK: - Internals

    /// Where a cut may sensibly be made.
    ///
    /// Not every residue: a solver that considers all N^2 ranges spends its time
    /// distinguishing boundaries that differ by one residue, which is a
    /// distinction nobody can act on. Boundaries come from three places that
    /// mean something: the edges of predicted disorder, the flanks of the
    /// annotated regions, and where other people actually cut.
    static func boundaryCandidates(
        residueCount: Int,
        disordered: [Bool],
        constraints: [ConstructConstraint],
        precedent: [ClosedRange<Int>]
    ) -> (starts: [Int], ends: [Int]) {
        var starts: Set<Int> = [0]
        var ends: Set<Int> = [residueCount - 1]

        // The first and last ordered residue: the maximal trim.
        if let firstOrdered = disordered.firstIndex(of: false) {
            starts.insert(firstOrdered)
        }
        if let lastOrdered = disordered.lastIndex(of: false) {
            ends.insert(lastOrdered)
        }

        // Every disorder boundary in the interior.
        for index in 1..<residueCount where disordered[index] != disordered[index - 1] {
            starts.insert(index)
            ends.insert(index - 1)
        }

        // Just outside each constrained region, so a construct can start
        // immediately before a motif or end immediately after one.
        for constraint in constraints {
            if constraint.range.lowerBound > 0 {
                ends.insert(constraint.range.lowerBound - 1)
            }
            if constraint.range.upperBound < residueCount - 1 {
                starts.insert(constraint.range.upperBound + 1)
            }
        }

        for range in precedent {
            if range.lowerBound >= 0, range.lowerBound < residueCount {
                starts.insert(range.lowerBound)
            }
            if range.upperBound >= 0, range.upperBound < residueCount {
                ends.insert(range.upperBound)
            }
        }

        return (starts.sorted(), ends.sorted())
    }

    /// Does a boundary fall strictly inside a constrained region?
    static func violates(
        _ range: ClosedRange<Int>, constraints: [ConstructConstraint]
    ) -> Bool {
        constraints.contains { constraint in
            let region = constraint.range
            let startsInside =
                region.contains(range.lowerBound) && range.lowerBound != region.lowerBound
            let endsInside =
                region.contains(range.upperBound) && range.upperBound != region.upperBound
            return startsInside || endsInside
        }
    }

    /// Does the construct keep every constrained region whole?
    ///
    /// Not the same question as `violates`. A construct can avoid cutting
    /// through a motif by excluding it entirely, which is legal for a signal
    /// peptide and wrong for a catalytic motif. Motifs and transmembrane spans
    /// must be RETAINED; signal peptides may be removed, which is usually the
    /// point of the construct.
    static func covers(
        _ range: ClosedRange<Int>, constraints: [ConstructConstraint]
    ) -> Bool {
        constraints.allSatisfy { constraint in
            switch constraint.kind {
            case .signalPeptide:
                return true
            case .motif, .transmembrane, .disulfide, .structuredCore:
                return range.lowerBound <= constraint.range.lowerBound
                    && range.upperBound >= constraint.range.upperBound
            }
        }
    }

    private static func evaluate(
        _ range: ClosedRange<Int>,
        residueCount: Int,
        disordered: [Bool],
        constraints: [ConstructConstraint],
        precedent: [ClosedRange<Int>]
    ) -> ConstructProposal {
        var rationale: [String] = []
        var score = 0.0

        let trimmedStart = range.lowerBound
        let trimmedEnd = residueCount - 1 - range.upperBound
        let removedDisorder = (0..<residueCount)
            .filter { !range.contains($0) && disordered[$0] }
            .count
        let keptDisorder = range.filter { disordered[$0] }.count

        // Removing disorder is the point. Keeping it costs.
        score += Double(removedDisorder) * 1.0
        score -= Double(keptDisorder) * 0.5

        if removedDisorder > 0 {
            rationale.append(
                "Removes \(removedDisorder) predicted disordered residues "
                    + "(\(trimmedStart) from the N terminus, \(trimmedEnd) from the C).")
        }
        if keptDisorder > 0 {
            rationale.append(
                "Retains \(keptDisorder) disordered residues inside the construct, "
                    + "which cannot be trimmed without splitting it.")
        }

        let removedSignal = constraints.first {
            $0.kind == .signalPeptide && $0.range.upperBound < range.lowerBound
        }
        if removedSignal != nil {
            score += 25
            rationale.append("Starts after the predicted signal peptide.")
        }

        let matches = precedent.filter {
            abs($0.lowerBound - range.lowerBound) <= precedentTolerance
                && abs($0.upperBound - range.upperBound) <= precedentTolerance
        }
        if !matches.isEmpty {
            score += Double(matches.count) * 10
            rationale.append(
                "\(matches.count) deposited "
                    + (matches.count == 1 ? "structure has" : "structures have")
                    + " boundaries within \(precedentTolerance) residues of this one.")
        }

        let kept = constraints.filter {
            $0.kind != .signalPeptide && range.lowerBound <= $0.range.lowerBound
                && range.upperBound >= $0.range.upperBound
        }
        if !kept.isEmpty {
            rationale.append(
                "Keeps \(kept.count) annotated "
                    + (kept.count == 1 ? "region" : "regions")
                    + " intact: \(kept.map(\.label).joined(separator: ", ")).")
        }

        // A mild preference for shorter constructs among equals: less to
        // express, less to go wrong. Deliberately small, so it never outweighs
        // precedent or disorder.
        score -= Double(range.count) * 0.01

        return ConstructProposal(
            range: range, rationale: rationale, score: score,
            precedentCount: matches.count)
    }
}
