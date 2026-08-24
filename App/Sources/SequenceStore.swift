//  SequenceStore.swift
//  BOFFIN
//
//  Holds the sequence under analysis and everything derived from it.
//
//  Derivation is deliberately eager and synchronous: the Phase 1 properties are
//  composition arithmetic over a few hundred residues, far below the threshold
//  where async machinery earns its complexity. Phase 2's model work is what
//  needs an actor, and it already has one.

import BoffinCore
import Observation
import SwiftUI

@MainActor
@Observable
final class SequenceStore {
    private(set) var sequence: ProteinSequence?
    private(set) var tracks: [AnyResidueTrack] = []
    private(set) var properties: SequenceProperties?
    private(set) var diagnostics: [FASTADiagnostic] = []
    private(set) var parseError: String?

    var selection: ClosedRange<Int>? {
        didSet { recomputeSelectionProperties() }
    }

    var pKaScale: PKaScale = .bjellqvist {
        didSet { recompute() }
    }

    var hydropathyWindow: Int = AnalyticalTracks.defaultHydropathyWindow {
        didSet { recompute() }
    }

    /// Properties over the current selection, or `nil` when nothing is selected.
    private(set) var selectionProperties: SequenceProperties?

    func load(text: String, fileName: String? = nil) {
        do {
            let result = try FASTAParser.parse(text, fileName: fileName)
            guard let first = result.sequences.first else {
                parseError = "No sequences were found in that input."
                return
            }
            sequence = first
            diagnostics = result.diagnostics
            parseError = nil
            selection = nil
            recompute()
        } catch FASTAParseError.empty {
            parseError = "That input was empty."
            clear()
        } catch FASTAParseError.noSequencesFound {
            parseError = "Headers were found but none had any residues under them."
            clear()
        } catch {
            parseError = "That input could not be read."
            clear()
        }
    }

    func clear() {
        sequence = nil
        tracks = []
        properties = nil
        selectionProperties = nil
        selection = nil
        diagnostics = []
    }

    private func recompute() {
        guard let sequence else { return }
        tracks = AnalyticalTracks.all(
            for: sequence, hydropathyWindow: hydropathyWindow, scale: pKaScale)
        properties = SequenceProperties(sequence, pKaScale: pKaScale)
        recomputeSelectionProperties()
    }

    private func recomputeSelectionProperties() {
        guard let sequence, let selection else {
            selectionProperties = nil
            return
        }
        let clamped = max(0, selection.lowerBound)...min(sequence.count - 1, selection.upperBound)
        guard clamped.lowerBound <= clamped.upperBound else {
            selectionProperties = nil
            return
        }
        selectionProperties = SequenceProperties(
            residues: Array(sequence.residues[clamped]), pKaScale: pKaScale)
    }
}
