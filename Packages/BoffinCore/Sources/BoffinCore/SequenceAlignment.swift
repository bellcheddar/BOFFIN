//  SequenceAlignment.swift
//  BoffinCore
//
//  Pairwise alignment, used to map a pasted sequence onto the bundled KLIFS and
//  GPCRdb numbering tables.
//
//  This exists because the KLIFS 85-residue pocket is DISCONTINUOUS in the
//  sequence: it is a structural pocket assembled from residues in several
//  regions, so it cannot be located by substring search. The pocket of a
//  reference kinase is aligned against the user's sequence, and the numbering
//  travels along the alignment.
//
//  Affine gaps, not linear. A linear penalty charges the same for opening a gap
//  as for extending one, so it prefers many short scattered gaps over one real
//  indel. On a kinase that scatters the pocket positions across the loop
//  insertions that distinguish families, which is precisely where the numbering
//  must not drift.

import Foundation

/// One position of an alignment.
public enum AlignmentColumn: Sendable, Hashable {
    /// Both sequences have a residue here.
    case match(query: Int, reference: Int)
    /// The reference has a residue the query does not.
    case referenceGap(reference: Int)
    /// The query has a residue the reference does not.
    case queryGap(query: Int)
}

public struct Alignment: Sendable, Hashable {
    public let columns: [AlignmentColumn]
    public let score: Int

    /// Query index for each reference index, where they align.
    ///
    /// This is the map the numbering travels along: reference position N of a
    /// curated table lands on this residue of the user's sequence.
    public func queryIndexByReference() -> [Int: Int] {
        var map: [Int: Int] = [:]
        for column in columns {
            if case .match(let query, let reference) = column { map[reference] = query }
        }
        return map
    }

    /// Identical residues as a fraction of the REFERENCE length.
    ///
    /// Not as a fraction of aligned columns, which is the tempting definition
    /// and a badly biased one: it excludes the gaps, so a query that aligns to
    /// only a fifth of the reference and happens to match there scores as
    /// highly as one that matches throughout. Measured here, ubiquitin scored
    /// 0.35 against a kinase pocket that way, which is not a resemblance, it is
    /// a short overlap flattered by its own denominator.
    ///
    /// Dividing by the reference length asks the question that matters: how
    /// much of the curated entry did this sequence actually reproduce?
    public func identity(query: [AminoAcid], reference: [AminoAcid]) -> Double {
        guard !reference.isEmpty else { return 0 }
        var identical = 0
        for column in columns {
            guard case .match(let q, let r) = column else { continue }
            guard q < query.count, r < reference.count else { continue }
            if query[q] == reference[r] { identical += 1 }
        }
        return Double(identical) / Double(reference.count)
    }

    /// Identical residues as a fraction of aligned columns only.
    ///
    /// Kept because it is the right statistic for comparing two sequences that
    /// genuinely correspond end to end, and named so it cannot be mistaken for
    /// the one above.
    public func identityOverAlignedColumns(query: [AminoAcid], reference: [AminoAcid]) -> Double {
        var aligned = 0
        var identical = 0
        for column in columns {
            guard case .match(let q, let r) = column else { continue }
            guard q < query.count, r < reference.count else { continue }
            aligned += 1
            if query[q] == reference[r] { identical += 1 }
        }
        return aligned > 0 ? Double(identical) / Double(aligned) : 0
    }
}

public enum SequenceAlignment {

    /// Gap penalties, BLAST's defaults for BLOSUM62.
    ///
    /// Taken from the published defaults rather than tuned: an aligner whose
    /// penalties were chosen to make one test pass is an aligner that will
    /// misalign the next protein.
    public static let gapOpen = -11
    public static let gapExtend = -1

    /// The largest alignment this will attempt, in matrix cells.
    ///
    /// Gotoh's algorithm is O(n*m) in both time and memory, and the memory is
    /// the binding constraint on a phone: the three score matrices for a
    /// 2,500-by-2,500 alignment are 150 MB. Homolog search returns entries up to
    /// 2,500 residues, so without a bound a single long hit against a long query
    /// would allocate more than the app's whole budget while the user waited.
    ///
    /// Nine million cells is a 3,000-by-3,000 alignment, comfortably above any
    /// pair the app aligns in practice (the index's median entry is 248
    /// residues) and well inside what fits. Beyond it the aligner returns an
    /// EMPTY alignment rather than a truncated or approximate one, so a caller
    /// sees no correspondence instead of a wrong one.
    public static let maximumCells = 9_000_000

    /// Global alignment with affine gaps (Needleman-Wunsch, Gotoh's algorithm).
    ///
    /// Global rather than local because the reference here is a curated
    /// full-length entry and the query is meant to be the same protein: a local
    /// alignment would happily match one well-conserved domain and silently
    /// ignore that the rest does not correspond.
    ///
    /// - Returns: the alignment, or an empty one when either sequence is empty
    ///   or the matrix would exceed ``maximumCells``.
    public static func align(query: [AminoAcid], reference: [AminoAcid]) -> Alignment {
        let n = query.count
        let m = reference.count
        guard n > 0, m > 0 else { return Alignment(columns: [], score: 0) }
        guard n * m <= maximumCells else { return Alignment(columns: [], score: 0) }

        let negativeInfinity = Int32.min / 4
        let width = m + 1

        // One flat buffer per matrix, indexed by `i * width + j`.
        //
        // These were `[[Int]]`, which is a row of pointers to independently
        // allocated rows: every access is two loads and a retain-free bounds
        // check on a separately allocated buffer, and the storage is 8 bytes a
        // cell plus per-row overhead. Flat Int32 halves the memory and removes
        // the indirection. Int32 is ample: the score is bounded by the sequence
        // length times BLOSUM62's maximum of 11.
        //
        // main          best score ending with query[i-1] against reference[j-1]
        // fromQuery     best score ending with a gap in the REFERENCE
        // fromReference best score ending with a gap in the QUERY
        var main = [Int32](repeating: negativeInfinity, count: (n + 1) * width)
        var fromQuery = main
        var fromReference = main

        main[0] = 0
        for i in 1...n { fromQuery[i * width] = Int32(gapOpen + gapExtend * (i - 1)) }
        for j in 1...m { fromReference[j] = Int32(gapOpen + gapExtend * (j - 1)) }

        let open = Int32(gapOpen)
        let extend = Int32(gapExtend)

        for i in 1...n {
            let row = i * width
            let previousRow = row - width
            let queryAcid = query[i - 1]
            for j in 1...m {
                let substitution = Int32(score(queryAcid, reference[j - 1]))
                let diagonal = previousRow + j - 1
                let best = max(
                    main[diagonal], max(fromQuery[diagonal], fromReference[diagonal]))
                main[row + j] = best + substitution

                fromQuery[row + j] = max(
                    main[previousRow + j] + open,
                    fromQuery[previousRow + j] + extend)
                fromReference[row + j] = max(
                    main[row + j - 1] + open,
                    fromReference[row + j - 1] + extend)
            }
        }

        // Traceback from whichever matrix holds the best final score.
        var columns: [AlignmentColumn] = []
        var i = n
        var j = m
        let corner = n * width + m
        var state = bestState(main[corner], fromQuery[corner], fromReference[corner])
        let finalScore = Int(max(main[corner], max(fromQuery[corner], fromReference[corner])))

        while i > 0 || j > 0 {
            switch state {
            case .main:
                guard i > 0, j > 0 else {
                    state = i > 0 ? .fromQuery : .fromReference
                    continue
                }
                columns.append(.match(query: i - 1, reference: j - 1))
                let substitution = Int32(score(query[i - 1], reference[j - 1]))
                let target = main[i * width + j] - substitution
                i -= 1
                j -= 1
                let cell = i * width + j
                state = bestState(
                    main[cell] == target ? target : negativeInfinity,
                    fromQuery[cell] == target ? target : negativeInfinity,
                    fromReference[cell] == target ? target : negativeInfinity)
                if state == .none { state = .main }

            case .fromQuery:
                guard i > 0 else { state = .main; continue }
                columns.append(.queryGap(query: i - 1))
                let opened = main[(i - 1) * width + j] + open == fromQuery[i * width + j]
                i -= 1
                state = opened ? .main : .fromQuery

            case .fromReference:
                guard j > 0 else { state = .main; continue }
                columns.append(.referenceGap(reference: j - 1))
                let opened = main[i * width + j - 1] + open == fromReference[i * width + j]
                j -= 1
                state = opened ? .main : .fromReference

            case .none:
                state = .main
            }
        }

        return Alignment(columns: columns.reversed(), score: finalScore)
    }

    private enum State { case main, fromQuery, fromReference, none }

    private static func bestState(
        _ main: Int32, _ fromQuery: Int32, _ fromReference: Int32
    )
        -> State
    {
        if main >= fromQuery && main >= fromReference { return .main }
        if fromQuery >= fromReference { return .fromQuery }
        return .fromReference
    }

    /// BLOSUM62 substitution score.
    public static func score(_ a: AminoAcid, _ b: AminoAcid) -> Int {
        AminoAcidTables.blosum62[a]?[b] ?? 0
    }
}
