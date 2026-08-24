//  ResidueTrackTests.swift
//  BoffinCoreTests
//
//  Invariant 2 is only worth anything if misalignment is caught. These tests
//  pin the alignment contract before any producer exists to violate it.

import Foundation
import Testing

@testable import BoffinCore

private func makeSequence(_ letters: String) -> ProteinSequence {
    ProteinSequence(name: "test", letters: letters, source: .fixture(name: "unit"))
}

@Suite("ResidueTrack alignment")
struct ResidueTrackAlignmentTests {

    @Test("A correctly sized continuous track validates")
    func continuousTrackValidates() throws {
        let sequence = makeSequence("MKVLA")
        let track = AnyResidueTrack(
            id: TrackID("disorder"),
            title: "Disorder",
            kind: .continuous,
            values: .continuous([0.1, 0.2, 0.9, 0.8, 0.3]),
            colourScheme: .sequential(min: 0, max: 1))

        try track.validate(against: sequence)
    }

    @Test("A short continuous track is rejected, not silently drawn")
    func shortTrackIsRejected() {
        let sequence = makeSequence("MKVLA")
        let track = AnyResidueTrack(
            id: TrackID("disorder"),
            title: "Disorder",
            kind: .continuous,
            values: .continuous([0.1, 0.2, 0.9]),
            colourScheme: .sequential(min: 0, max: 1))

        #expect(
            throws: TrackAlignmentError.countMismatch(
                track: TrackID("disorder"), expected: 5, found: 3)
        ) {
            try track.validate(against: sequence)
        }
    }

    @Test("A span running past the C-terminus is rejected")
    func spanOutOfBoundsIsRejected() {
        let sequence = makeSequence("MKVLA")
        let track = AnyResidueTrack(
            id: TrackID("tm"),
            title: "TM spans",
            kind: .span,
            values: .spans([TrackSpan(start: 3, end: 9, label: "TM1")]),
            colourScheme: .solid)

        #expect(throws: TrackAlignmentError.self) {
            try track.validate(against: sequence)
        }
    }

    @Test("An inverted span is rejected")
    func invertedSpanIsRejected() {
        let sequence = makeSequence("MKVLA")
        let track = AnyResidueTrack(
            id: TrackID("motif"),
            title: "Motifs",
            kind: .span,
            values: .spans([TrackSpan(start: 4, end: 1, label: "backwards")]),
            colourScheme: .solid)

        #expect(throws: TrackAlignmentError.self) {
            try track.validate(against: sequence)
        }
    }

    @Test("A delta-LLR matrix has one column per residue and one row per amino acid")
    func matrixTrackValidates() throws {
        let sequence = makeSequence("MKVLA")
        let rows = AminoAcid.canonical.map { String($0.code) }
        let columns = Array(
            repeating: Array(repeating: Double?.some(0), count: rows.count), count: 5)
        let track = AnyResidueTrack(
            id: TrackID("llr"),
            title: "Delta LLR",
            kind: .matrix,
            values: .matrix(rows: rows, columns: columns),
            colourScheme: .diverging(min: -10, mid: 0, max: 10))

        try track.validate(against: sequence)
    }

    @Test("A ragged matrix column is rejected")
    func raggedMatrixIsRejected() {
        let sequence = makeSequence("MK")
        let rows = ["A", "C", "D"]
        let columns: [[Double?]] = [[0, 0, 0], [0, 0]]
        let track = AnyResidueTrack(
            id: TrackID("llr"),
            title: "Delta LLR",
            kind: .matrix,
            values: .matrix(rows: rows, columns: columns),
            colourScheme: .diverging(min: -10, mid: 0, max: 10))

        #expect(throws: TrackAlignmentError.self) {
            try track.validate(against: sequence)
        }
    }
}
