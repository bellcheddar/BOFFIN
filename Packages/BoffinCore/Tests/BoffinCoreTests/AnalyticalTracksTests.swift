//  AnalyticalTracksTests.swift
//  BoffinCoreTests

import Foundation
import Testing

@testable import BoffinCore

private func sequence(_ letters: String) -> ProteinSequence {
    ProteinSequence(name: "t", letters: letters, source: .fixture(name: "unit"))
}

@Suite("Analytical tracks")
struct AnalyticalTracksTests {

    @Test("Every analytical track aligns with its sequence")
    func tracksValidate() throws {
        // Invariant 2's guard rail: a producer that emits a misaligned track
        // draws a convincing picture of the wrong thing.
        let protein = sequence("MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQ")
        for track in AnalyticalTracks.all(for: protein) {
            try track.validate(against: protein)
        }
    }

    @Test("Hydropathy leaves the termini blank rather than averaging a short window")
    func terminiAreBlank() {
        // A half-window average is a different statistic wearing the same
        // colour, and the termini are exactly where construct boundaries get
        // chosen.
        let track = AnalyticalTracks.hydropathy(
            of: sequence(String(repeating: "A", count: 20)), window: 9)
        guard case .continuous(let values) = track.values else {
            Issue.record("expected a continuous track")
            return
        }
        #expect(values[0] == nil)
        #expect(values[3] == nil)
        #expect(values[4] != nil)
        #expect(values[15] != nil)
        #expect(values[16] == nil)
        #expect(values[19] == nil)
    }

    @Test("A homopolymer's hydropathy equals that residue's value")
    func homopolymerHydropathy() {
        let track = AnalyticalTracks.hydropathy(of: sequence(String(repeating: "I", count: 20)))
        guard case .continuous(let values) = track.values else {
            Issue.record("expected a continuous track")
            return
        }
        #expect(abs((values[10] ?? 0) - 4.5) < 1e-12)
    }

    @Test("A sequence shorter than the window produces no hydropathy values")
    func shortSequenceHasNoWindow() {
        let track = AnalyticalTracks.hydropathy(of: sequence("MKV"), window: 9)
        guard case .continuous(let values) = track.values else {
            Issue.record("expected a continuous track")
            return
        }
        #expect(values.count == 3)
        #expect(values.allSatisfy { $0 == nil })
    }

    @Test("A window containing a non-canonical residue is left blank")
    func windowWithNonCanonicalIsBlank() {
        // Averaging over the residues that happen to be recognisable would
        // silently report a 9-residue window computed from 8.
        let track = AnalyticalTracks.hydropathy(of: sequence("AAAAXAAAAAAAAA"), window: 9)
        guard case .continuous(let values) = track.values else {
            Issue.record("expected a continuous track")
            return
        }
        #expect(values[4] == nil, "window centred on the X should be blank")
        #expect(values[8] == nil, "window still containing the X should be blank")
        #expect(values[9] != nil, "window clear of the X should have a value")
    }

    @Test("Hydropathy uses the published domain, not the data range")
    func hydropathyDomainIsFixed() {
        // A scale taken from the data changes per sequence, so two proteins
        // cannot be compared by eye. Kyte-Doolittle runs -4.5 to +4.5.
        let track = AnalyticalTracks.hydropathy(of: sequence("MKVLA"))
        guard case .diverging(let minimum, let mid, let maximum) = track.colourScheme else {
            Issue.record("expected a diverging scheme")
            return
        }
        #expect(minimum == -4.5)
        #expect(mid == 0)
        #expect(maximum == 4.5)
    }

    @Test("Charge is positive for basic residues and negative for acidic")
    func chargeSigns() {
        let track = AnalyticalTracks.charge(of: sequence("KRDEA"), pH: 7.4)
        guard case .continuous(let values) = track.values else {
            Issue.record("expected a continuous track")
            return
        }
        #expect((values[0] ?? 0) > 0.9, "Lys should be nearly fully protonated at pH 7.4")
        #expect((values[1] ?? 0) > 0.9, "Arg should be nearly fully protonated")
        #expect((values[2] ?? 0) < -0.9, "Asp should be nearly fully deprotonated")
        #expect((values[3] ?? 0) < -0.9, "Glu should be nearly fully deprotonated")
        #expect(values[4] == 0, "Ala has no ionisable side chain")
    }

    @Test("Histidine is around half protonated near its pKa")
    func histidineNearItsPKa() {
        // Bjellqvist gives His a side chain pKa of 5.98, so at that pH it must
        // be half charged. A sign or exponent error here would not be visible
        // in the plot.
        let track = AnalyticalTracks.charge(of: sequence("H"), pH: 5.98)
        guard case .continuous(let values) = track.values else {
            Issue.record("expected a continuous track")
            return
        }
        #expect(abs((values[0] ?? 0) - 0.5) < 1e-9)
    }

    @Test("Non-canonical runs become spans")
    func nonCanonicalSpans() {
        let track = AnalyticalTracks.nonCanonical(of: sequence("MKXXXVLAUU"))
        guard let track, case .spans(let spans) = track.values else {
            Issue.record("expected spans")
            return
        }
        #expect(spans.count == 2)
        #expect(spans[0].start == 2 && spans[0].end == 4)
        #expect(spans[1].start == 8 && spans[1].end == 9)
    }

    @Test("A clean sequence produces no non-canonical track at all")
    func cleanSequenceHasNoTrack() {
        // An empty track would draw an empty row, which reads as "checked and
        // found nothing" only if you know to expect it. Better to omit it.
        #expect(AnalyticalTracks.nonCanonical(of: sequence("MKVLA")) == nil)
    }

    @Test("A trailing non-canonical run is closed at the C-terminus")
    func trailingRunIsClosed() {
        let track = AnalyticalTracks.nonCanonical(of: sequence("MKXX"))
        guard let track, case .spans(let spans) = track.values else {
            Issue.record("expected spans")
            return
        }
        #expect(spans.count == 1)
        #expect(spans[0].end == 3)
    }
}
