//  LLRMatrix.swift
//  BoffinCore
//
//  The delta-LLR substitution matrix: for every position, how much the model
//  prefers each of the twenty canonical residues over the wild type.
//
//  Lives in BoffinCore rather than BoffinML because it is a value type with no
//  dependency on Core ML. Keeping it here means the Fitness tab's rendering,
//  export and mutation basket can all be built and tested without a model
//  present, and BoffinCharts (which may not see BoffinML) can draw it.

import Foundation

/// Delta log-likelihood ratios for every canonical substitution at every
/// scored position.
///
/// `ΔLLR(i, mt) = log P(mt | x_masked(i)) − log P(wt | x_masked(i))`
///
/// Negative means the model prefers the wild type, which is the usual case.
/// Positive means the model would rather see the substitution.
public struct LLRMatrix: Sendable, Hashable {

    /// Row order, fixed to `AminoAcid.canonical`. Every consumer relies on this
    /// being stable: a reordering would silently transpose the meaning of every
    /// cached matrix and exported CSV.
    public let rows: [AminoAcid]

    /// Sequence positions that were scored, in ascending order.
    ///
    /// Not necessarily every residue: non-canonical positions cannot be scored,
    /// and a user may score a selection.
    public let positions: [Int]

    /// Wild-type residue at each scored position, parallel to `positions`.
    public let wildType: [AminoAcid]

    /// `values[column][row]`, column-major to match how the heatmap is drawn
    /// (one column per position) and how the scorer produces it.
    public let values: [[Double]]

    public init(
        rows: [AminoAcid] = AminoAcid.canonical,
        positions: [Int],
        wildType: [AminoAcid],
        values: [[Double]]
    ) {
        self.rows = rows
        self.positions = positions
        self.wildType = wildType
        self.values = values
    }

    public var columnCount: Int { positions.count }
    public var rowCount: Int { rows.count }

    /// The score for one substitution, or `nil` if that position was not scored.
    public func score(at position: Int, to residue: AminoAcid) -> Double? {
        guard let column = positions.firstIndex(of: position),
            let row = rows.firstIndex(of: residue)
        else { return nil }
        return values[column][row]
    }

    /// The most and least tolerated substitutions at a position.
    public func extremes(at position: Int) -> (best: AminoAcid, worst: AminoAcid)? {
        guard let column = positions.firstIndex(of: position) else { return nil }
        let scores = values[column]
        guard
            let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
            let worstIndex = scores.indices.min(by: { scores[$0] < scores[$1] })
        else { return nil }
        return (rows[bestIndex], rows[worstIndex])
    }

    /// Symmetric bound for the colour scale, so zero sits at the midpoint.
    ///
    /// Derived from the data rather than fixed, because delta-LLR range depends
    /// on the protein: but symmetric, because an asymmetric diverging scale puts
    /// zero off-centre and makes tolerated and deleterious substitutions look
    /// like different magnitudes than they are.
    public var symmetricBound: Double {
        let magnitude = values.flatMap { $0 }.map(abs).max() ?? 1
        return magnitude > 0 ? magnitude : 1
    }

    /// Mean score per position: a single-number summary of how constrained each
    /// site is. More negative means less tolerant of substitution.
    public var meanPerPosition: [Double] {
        values.map { column in
            column.isEmpty ? 0 : column.reduce(0, +) / Double(column.count)
        }
    }

    /// The matrix as a `ResidueTrack`, aligned to the full sequence.
    ///
    /// Positions that were not scored are `nil` rather than zero: zero is a
    /// real delta-LLR meaning "no preference", and using it for "not measured"
    /// would paint unscored residues as perfectly tolerant.
    public func track(residueCount: Int) -> AnyResidueTrack {
        let names = rows.map { String($0.code) }
        var columns = [[Double?]](
            repeating: [Double?](repeating: nil, count: rows.count),
            count: residueCount)
        for (index, position) in positions.enumerated() where position < residueCount {
            columns[position] = values[index].map { Optional($0) }
        }
        let bound = symmetricBound
        return AnyResidueTrack(
            id: TrackID("delta-llr"),
            title: "Delta LLR",
            kind: .matrix,
            values: .matrix(rows: names, columns: columns),
            colourScheme: .diverging(min: -bound, mid: 0, max: bound))
    }

    /// Comma-separated export, positions as columns.
    ///
    /// One-based positions, because that is what every other tool and every
    /// paper uses. Exporting zero-based indices would be internally consistent
    /// and wrong everywhere it was pasted.
    public func commaSeparatedValues() -> String {
        var lines: [String] = []
        let header = ["substitution"] + zip(positions, wildType).map { "\($0.1.code)\($0.0 + 1)" }
        lines.append(header.joined(separator: ","))

        for (rowIndex, residue) in rows.enumerated() {
            var line = [String(residue.code)]
            for column in values {
                line.append(String(format: "%.4f", column[rowIndex]))
            }
            lines.append(line.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One substitution a user has collected.
public struct Mutation: Sendable, Hashable, Identifiable, Codable {
    public let position: Int
    public let wildType: AminoAcid
    public let substitution: AminoAcid
    public let score: Double

    public var id: String { label }

    /// Conventional mutation notation, one-based: `K48R`.
    public var label: String {
        "\(wildType.code)\(position + 1)\(substitution.code)"
    }

    public init(position: Int, wildType: AminoAcid, substitution: AminoAcid, score: Double) {
        self.position = position
        self.wildType = wildType
        self.substitution = substitution
        self.score = score
    }
}
