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

    // MARK: - Family

    private(set) var motifs: [MotifFamily: [Motif]] = [:]

    // MARK: - Fitness

    private(set) var llr: LLRMatrix?
    private(set) var llrMode: ScoringMode?
    private(set) var scanState: ScanState = .idle
    var mutations: [Mutation] = []
    var maskDisordered = false

    private var scanTask: Task<Void, Never>?

    enum ScanState: Equatable {
        case idle
        case running(fraction: Double)
        case ready
        case failed(String)
        case cancelled
    }
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

    /// All tracks for the ruler: analytical, then motifs, then model-derived.
    var allTracks: [AnyResidueTrack] {
        var all = tracks
        if let motifTrack = FamilyMotifs.track(motifs.values.flatMap { $0 }) {
            all.append(motifTrack)
        }
        return all + modelTracks
    }

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
            motifs = [:]
            llr = nil
            llrMode = nil
            mutations = []
            scanTask?.cancel()
            scanState = .idle
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

    /// Score substitutions across the sequence.
    ///
    /// The fast mode is one forward pass and returns almost immediately; the
    /// masked-marginal mode is one pass per position and is cancellable.
    func scan(mode: ScoringMode) {
        guard let sequence, let bundle = Self.modelDirectory else { return }
        scanTask?.cancel()
        scanState = .running(fraction: 0)

        // Disorder masking narrows the scan to ordered positions. Scoring a
        // disordered region is rarely actionable, and in the slow mode it is
        // most of the wait. Computed here, on the main actor, so the task body
        // captures plain values rather than reaching back into the store.
        var positions: [Int]?
        if maskDisordered, let called = predictions?.isDisordered {
            positions = called.indices.filter { !called[$0] }
        }
        let scanPositions = positions

        // Strong capture, not weak. The progress callback is @Sendable and
        // cannot reach back through a weak optional binding; the store is
        // @MainActor (and so implicitly Sendable) and the task is cancelled
        // whenever the sequence changes, so holding it for the scan is safe.
        scanTask = Task { @MainActor in
            do {
                let engine = try EmbeddingEngine(
                    modelURL: bundle.appending(path: "esm2_t12_35M_UR50D.mlpackage"),
                    tokeniserURL: bundle.appending(path: "esm2_t12_35M_UR50D.tokeniser.json"))

                let matrix = try await engine.maskedMarginals(
                    sequence, positions: scanPositions, mode: mode
                ) { progress in
                    Task { @MainActor in self.report(progress) }
                }
                self.llr = matrix
                self.llrMode = mode
                self.scanState = .ready
            } catch is CancellationError {
                self.scanState = .cancelled
            } catch {
                self.scanState = .failed(String(describing: error))
            }
        }
    }

    /// Relay scan progress. Separate method so the @Sendable callback has a
    /// single main-actor entry point rather than mutating state inline.
    private func report(_ progress: ScanProgress) {
        if case .running = scanState {
            scanState = .running(fraction: progress.fraction)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .cancelled
    }

    func toggle(_ mutation: Mutation) {
        if let index = mutations.firstIndex(of: mutation) {
            mutations.remove(at: index)
        } else {
            mutations.append(mutation)
        }
    }

    private func recompute() {
        guard let sequence else { return }
        // Motifs are pure sequence pattern matching: no model, no network, and
        // available the instant a sequence is pasted.
        motifs = FamilyMotifs.all(in: sequence)
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
