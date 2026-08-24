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
import BoffinML
import Observation
import SwiftUI

@MainActor
@Observable
final class SequenceStore {
    private(set) var sequence: ProteinSequence?
    private(set) var tracks: [AnyResidueTrack] = []

    /// Model-derived tracks, kept separate from the analytical ones so the UI
    /// can say which is which. A user is entitled to know that hydropathy is
    /// arithmetic and disorder is a prediction.
    private(set) var modelTracks: [AnyResidueTrack] = []
    private(set) var predictions: HeadPredictions?
    private(set) var modelState: ModelState = .idle

    enum ModelState: Equatable {
        case idle
        case running
        case ready(passes: Int)
        /// The model is optional: the app is fully usable without it, so a
        /// failure downgrades rather than blocking.
        case unavailable(String)
    }
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

    /// All tracks for the ruler: analytical first, then model-derived.
    var allTracks: [AnyResidueTrack] { tracks + modelTracks }

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
            modelTracks = []
            predictions = nil
            modelState = .idle
            recompute()
            Task { await runModel() }
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

    /// Run the backbone once, then both heads off that single pass.
    ///
    /// Invariant 1: one forward pass, four fan-outs. The heads read the hidden
    /// states the backbone already produced rather than re-running it.
    private func runModel() async {
        guard let sequence else { return }
        guard let bundle = Self.modelDirectory else {
            modelState = .unavailable(
                "Analysis models are not bundled in this build.")
            return
        }

        modelState = .running
        do {
            let engine = try EmbeddingEngine(
                modelURL: bundle.appending(path: "esm2_t12_35M_UR50D.mlpackage"),
                tokeniserURL: bundle.appending(path: "esm2_t12_35M_UR50D.tokeniser.json"))
            let embedding = try await engine.embed(sequence)

            let heads = try AnalysisHeads(directory: bundle.appending(path: "heads"))
            let result = try await heads.predict(for: embedding)

            // Validate before showing: a track that does not line up with the
            // sequence draws a convincing picture of the wrong thing.
            let candidates = result.tracks()
            for track in candidates { try track.validate(against: sequence) }

            predictions = result
            modelTracks = candidates
            modelState = .ready(passes: embedding.passes)
        } catch {
            modelTracks = []
            predictions = nil
            modelState = .unavailable(String(describing: error))
        }
    }

    /// Where the bundled models live.
    ///
    /// Falls back to the repository's `Models/` folder during development,
    /// because the 67 MB backbone is a build artefact and is not committed.
    private static var modelDirectory: URL? {
        if let bundled = Bundle.main.url(forResource: "Models", withExtension: nil) {
            return bundled
        }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Models")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        #endif
        return nil
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
