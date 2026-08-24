//  AnalyticalTracks.swift
//  BoffinCore
//
//  Tracks that need no model: pure composition arithmetic, available the
//  instant a sequence is pasted and identical offline. They are the Phase 1
//  proof that invariant 2 holds before there is anything to fan out from.

import Foundation

public enum AnalyticalTracks {

    /// Window size for the hydropathy plot, in residues.
    ///
    /// Kyte and Doolittle used a span of 7 for general hydropathy and 19 for
    /// identifying membrane-spanning segments. Nine is a common middle choice
    /// and is the default here, but it is exposed rather than buried: the
    /// window changes what the plot appears to say, so the user can see and
    /// change it.
    public static let defaultHydropathyWindow = 9

    /// Windowed Kyte-Doolittle hydropathy.
    ///
    /// Positions where the window would run off either end are left `nil`
    /// rather than being computed from a truncated window. A half-window
    /// average is a different statistic wearing the same colour, and at the
    /// termini (exactly where a construct boundary gets chosen) that matters.
    public static func hydropathy(
        of sequence: ProteinSequence,
        window: Int = defaultHydropathyWindow
    ) -> AnyResidueTrack {
        let half = window / 2
        var values = [Double?](repeating: nil, count: sequence.count)

        if sequence.count >= window {
            for centre in half..<(sequence.count - half) {
                var total = 0.0
                var counted = 0
                for offset in (centre - half)...(centre + half) {
                    guard case .canonical(let acid) = sequence.residues[offset].identity,
                        let hydropathy = AminoAcidTables.kyteDoolittleHydropathy[acid]
                    else { continue }
                    total += hydropathy
                    counted += 1
                }
                // A window containing any non-canonical residue is not a
                // Kyte-Doolittle average over `window` residues, so it is left
                // blank rather than being quietly computed over fewer.
                if counted == window { values[centre] = total / Double(window) }
            }
        }

        return AnyResidueTrack(
            id: TrackID("hydropathy"),
            title: "Hydropathy (Kyte-Doolittle, window \(window))",
            kind: .continuous,
            values: .continuous(values),
            // Kyte-Doolittle runs from -4.5 (Arg) to +4.5 (Ile), so the domain
            // is fixed rather than taken from the data: a track whose scale
            // changes per sequence cannot be compared between sequences.
            colourScheme: .diverging(min: -4.5, mid: 0, max: 4.5))
    }

    /// Net charge contributed by each residue at a given pH.
    ///
    /// Per-residue rather than cumulative, so the track shows where the charge
    /// actually sits along the chain: the thing you look at when deciding where
    /// an ion exchange column will grip.
    public static func charge(
        of sequence: ProteinSequence,
        pH: Double = 7.4,
        scale: PKaScale = .bjellqvist
    ) -> AnyResidueTrack {
        let values = sequence.residues.map { residue -> Double? in
            guard case .canonical(let acid) = residue.identity else { return nil }
            let pKaValues = scale.values
            if let pKa = pKaValues.basicSideChains[acid] {
                return 1.0 / (pow(10.0, pH - pKa) + 1.0)
            }
            if let pKa = pKaValues.acidicSideChains[acid] {
                return -1.0 / (pow(10.0, pKa - pH) + 1.0)
            }
            return 0
        }

        return AnyResidueTrack(
            id: TrackID("charge"),
            title: "Side chain charge at pH \(String(format: "%.1f", pH))",
            kind: .continuous,
            values: .continuous(values),
            colourScheme: .diverging(min: -1, mid: 0, max: 1))
    }

    /// Positions that cannot be scored, as spans.
    ///
    /// Surfacing these as a track rather than a footnote means a run of
    /// unknown residues is visible in the same place the user is already
    /// looking, instead of being something they have to remember to check.
    public static func nonCanonical(of sequence: ProteinSequence) -> AnyResidueTrack? {
        var spans: [TrackSpan] = []
        var runStart: Int?

        for residue in sequence.residues {
            if residue.identity.isScorable {
                if let start = runStart {
                    spans.append(
                        TrackSpan(start: start, end: residue.index - 1, label: "non-canonical"))
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = residue.index
            }
        }
        if let start = runStart {
            spans.append(
                TrackSpan(start: start, end: sequence.count - 1, label: "non-canonical"))
        }

        guard !spans.isEmpty else { return nil }
        return AnyResidueTrack(
            id: TrackID("non-canonical"),
            title: "Non-canonical residues",
            kind: .span,
            values: .spans(spans),
            colourScheme: .solid)
    }

    /// Every analytical track available for a sequence, in display order.
    public static func all(
        for sequence: ProteinSequence,
        hydropathyWindow: Int = defaultHydropathyWindow,
        pH: Double = 7.4,
        scale: PKaScale = .bjellqvist
    ) -> [AnyResidueTrack] {
        var tracks = [
            hydropathy(of: sequence, window: hydropathyWindow),
            charge(of: sequence, pH: pH, scale: scale),
        ]
        if let nonCanonical = nonCanonical(of: sequence) { tracks.append(nonCanonical) }
        return tracks
    }
}
