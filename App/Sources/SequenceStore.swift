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
import BoffinData
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
    private(set) var numbering: NumberingResult?
    private(set) var numberingScheme: String?
    /// Named kinase pocket landmarks: gatekeeper, hinge, DFG, beta-3 lysine.
    private(set) var pocketAnchors: [PocketAnchor] = []
    private(set) var familyCall: FamilyClassification?

    /// Homolog hits, aligned to the query so each carries a real identity and
    /// residue-level PDB numbering rather than only a cosine.
    private(set) var homologs: [HomologAlignment] = []
    private(set) var homologState: HomologState = .idle
    /// Deposited constructs for the best hit: the crystallisation precedent
    /// Phase 6 plans against.
    private(set) var precedent: [ObservedConstruct] = []

    enum HomologState: Equatable {
        case idle
        case searching
        case ready(count: Int)
        /// The index is a downloadable asset, so its absence is an ordinary
        /// state and never an error the user has to act on.
        case unavailable(String)
    }

    // MARK: - Boundary

    /// Proposed constructs, or the reason there are none.
    private(set) var constructs: ConstructSolverResult = .declined(
        "Load a sequence to propose constructs.")

    /// The regions no construct boundary may fall inside, with where each came
    /// from, so the UI can say what is being enforced rather than only that
    /// something is.
    private(set) var constructConstraints: [ConstructConstraint] = []

    /// Tag placement and protease choice for the best proposal.
    private(set) var tagPlan: TagPlan?

    /// The best proposal written out, ready to share.
    private(set) var constructCard: ConstructCard?

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
        if let numbering, let scheme = numberingScheme, let sequence,
            let track = FamilyStore.track(
                numbering, residueCount: sequence.count, title: scheme)
        {
            all.append(track)
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
            numbering = nil
            numberingScheme = nil
            familyCall = nil
            constructs = .declined("Analysing.")
            constructConstraints = []
            tagPlan = nil
            constructCard = nil
            homologs = []
            precedent = []
            homologState = .idle
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
            // Swift 6.2 warns that this is unreachable and then refuses to
            // compile without it ("the enclosing catch is not exhaustive").
            // Both cannot be true; the warning is the wrong half. Leave it.
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
            modelState = .unavailable(Self.modelsMissingMessage)
            return
        }

        modelState = .running
        do {
            let engine = try EmbeddingEngine(
                modelURL: bundle.appending(path: Self.backboneName),
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
            // The third fan-out from the same pass.
            familyCall = try? await heads.classifyFamily(for: embedding)
            modelState = .ready(passes: embedding.passes)
            // The fourth, off the same vector: no extra inference at all.
            await searchHomologs(pooled: embedding.pooled, sequence: sequence)
            // Constructs need the disorder and topology tracks AND the homolog
            // precedent, so this runs last.
            recomputeConstructs()
        } catch {
            modelTracks = []
            predictions = nil
            modelState = .unavailable(String(describing: error))
        }
    }

    /// Assemble the solver's inputs from three modules that cannot see each
    /// other, and run it.
    ///
    /// The adaptation lives here on purpose. `ConstructSolver` is in BoffinCore
    /// and knows nothing about topology heads or SIFTS: it reasons about regions
    /// that must not be cut and about where other people have cut before. The
    /// app is the only place that can see all three sources, which is the
    /// dependency rule working rather than a workaround.
    private func recomputeConstructs() {
        guard let sequence else {
            constructs = .declined("Load a sequence to propose constructs.")
            constructConstraints = []
            return
        }

        var constraints: [ConstructConstraint] = []

        for (family, found) in motifs {
            for motif in found {
                constraints.append(
                    ConstructConstraint(
                        kind: .motif,
                        range: motif.range.lowerBound...motif.range.upperBound,
                        label: "\(displayName(family)) \(motif.name)"))
            }
        }

        for span in predictions?.topologySpans() ?? [] {
            constraints.append(
                ConstructConstraint(
                    kind: span.kind == .signalPeptide ? .signalPeptide : .transmembrane,
                    range: span.range,
                    label: span.kind == .signalPeptide
                        ? "signal peptide" : "transmembrane span"))
        }

        constructConstraints = constraints.sorted {
            $0.range.lowerBound < $1.range.lowerBound
        }

        // Precedent, mapped into THIS sequence's coordinates through the best
        // homolog's alignment. A deposited range in the homolog's UniProt
        // numbering means nothing here until it has been carried across, and
        // carrying it across is what the alignment is for.
        var deposited: [ClosedRange<Int>] = []
        if let best = homologs.first {
            for construct in precedent {
                guard let first = queryIndex(forUniProt: construct.first, in: best),
                    let last = queryIndex(forUniProt: construct.last, in: best),
                    first <= last
                else { continue }
                deposited.append(first...last)
            }
        }

        constructs = ConstructSolver.propose(
            residueCount: sequence.count,
            disordered: predictions?.isDisordered ?? [],
            constraints: constructConstraints,
            precedent: deposited)

        tagPlan = nil
        constructCard = nil
        if let best = constructs.proposals.first {
            let residues = best.range.compactMap { index -> AminoAcid? in
                guard sequence.residues.indices.contains(index) else { return nil }
                if case .canonical(let acid) = sequence.residues[index].identity {
                    return acid
                }
                return nil
            }
            let disordered = predictions?.isDisordered ?? []
            func isDisordered(_ index: Int) -> Bool {
                disordered.indices.contains(index) ? disordered[index] : false
            }
            let plan = TagPlanner.plan(
                construct: residues,
                hasSignalPeptide: constructConstraints.contains { $0.kind == .signalPeptide },
                startsDisordered: isDisordered(best.range.lowerBound),
                endsDisordered: isDisordered(best.range.upperBound))
            tagPlan = plan
            constructCard = ConstructCard(
                proteinName: sequence.name,
                range: (best.range.lowerBound + 1)...(best.range.upperBound + 1),
                residues: residues,
                rationale: best.rationale,
                tagPlan: plan,
                linker: Linker.conventional(
                    forDisorderedTerminus: plan.terminus == .aminoTerminal
                        ? isDisordered(best.range.lowerBound)
                        : isDisordered(best.range.upperBound)),
                properties: SequenceProperties(
                    residues: Array(sequence.residues[best.range]), pKaScale: pKaScale),
                pKaScale: pKaScale,
                precedentCount: best.precedentCount,
                constraints: constructConstraints,
                dna: ReverseTranslator.translate(residues))
        }
    }

    /// Where a homolog's UniProt residue number lands in the user's sequence.
    private func queryIndex(forUniProt number: Int, in alignment: HomologAlignment) -> Int? {
        guard let sequence else { return nil }
        for index in 0..<sequence.count {
            if case .mapped(_, let uniprot) = alignment.mapping(forQueryResidue: index),
                uniprot == number
            {
                return index
            }
        }
        return nil
    }

    private func displayName(_ family: MotifFamily) -> String {
        switch family {
        case .proteinKinase: "protein kinase"
        case .classAGPCR: "class A GPCR"
        }
    }

    /// Search the bundled index for proteins whose pooled embedding is close.
    ///
    /// The alignment of each hit runs off the main actor: it is a few million
    /// dynamic-programming cells and would be visible as a stutter otherwise.
    private func searchHomologs(pooled: [Float], sequence: ProteinSequence) async {
        guard let assets = Self.assetDirectory else {
            homologState = .unavailable("The homolog index has not been downloaded.")
            return
        }
        homologState = .searching
        let query = sequence.residues.compactMap { residue -> AminoAcid? in
            if case .canonical(let acid) = residue.identity { return acid }
            return nil
        }

        let limit = Self.homologLimit
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> Result<[HomologAlignment], any Error> in
            do {
                let index = try HomologIndex(
                    vectors: assets.appending(path: "homolog_vectors.bin"),
                    metadata: assets.appending(path: "homolog_meta.bin"))
                let hits = try index.search(pooled, limit: limit)
                let sifts = try? SIFTSStore(url: assets.appending(path: "sifts_segments.bin"))
                let aligned = hits.map { hit in
                    HomologAlignment(
                        hit: hit,
                        query: query,
                        reference: hit.sequence.compactMap { AminoAcid(rawValue: $0) },
                        segments: sifts?.segments(for: hit.accession) ?? [])
                }
                return .success(aligned)
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let aligned):
            homologs = aligned
            homologState = .ready(count: aligned.count)
            if let best = aligned.first,
                let sifts = try? SIFTSStore(
                    url: assets.appending(path: "sifts_segments.bin"))
            {
                precedent = Array(sifts.constructs(for: best.hit.accession).prefix(20))
            }
        case .failure(let error):
            homologs = []
            precedent = []
            homologState = .unavailable(String(describing: error))
        }
    }

    /// How many hits to align and show.
    ///
    /// The search itself is exhaustive and costs the same whatever this is; the
    /// limit is on how many alignments are computed, since each is a full
    /// Needleman-Wunsch matrix against the hit.
    private static let homologLimit = 12

    /// Where the downloadable assets live.
    ///
    /// The index and SIFTS tables are about 110 MB, so they ship through
    /// Background Assets rather than inside the app. During development they
    /// are read straight out of the repository's `Assets/` folder.
    private static var assetDirectory: URL? {
        if let bundled = Bundle.main.url(forResource: "Assets", withExtension: nil) {
            return bundled
        }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Assets")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        #endif
        return nil
    }

    /// Shown wherever the absence of the converted model stops something.
    ///
    /// One string, so the UI test can look for it and so the two places that
    /// report it cannot drift apart.
    static let modelsMissingMessage = "Analysis models are not bundled in this build."

    /// Where the bundled models live.
    ///
    /// Falls back to the repository's `Models/` folder during development,
    /// because the 67 MB backbone is a build artefact and is not committed.
    private static var modelDirectory: URL? {
        // Check for the BACKBONE, not for the folder.
        //
        // `Models/` exists in a clean checkout because the heads' JSON metadata
        // is committed; the 67 MB `.mlpackage` is not. Testing the directory
        // therefore reported the models as present on CI, the engine then failed
        // to load with a Core ML error, and the app showed that error instead of
        // "models are not bundled". The UI test was looking for the second and
        // saw neither a heatmap nor the explanation it expected.
        func hasBackbone(_ directory: URL) -> Bool {
            FileManager.default.fileExists(
                atPath: directory.appending(path: backboneName).path)
        }
        if let bundled = Bundle.main.url(forResource: "Models", withExtension: nil),
            hasBackbone(bundled)
        {
            return bundled
        }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Models")
        if hasBackbone(development) { return development }
        #endif
        return nil
    }

    /// The converted backbone's package name, in one place because three call
    /// sites need to agree about it.
    private static let backboneName = "esm2_t12_35M_UR50D.mlpackage"

    /// Score substitutions across the sequence.
    ///
    /// The fast mode is one forward pass and returns almost immediately; the
    /// masked-marginal mode is one pass per position and is cancellable.
    func scan(mode: ScoringMode) {
        guard let sequence else { return }
        // Returning silently here is what this used to do, and it meant that on
        // a build without the converted model the button did nothing at all: no
        // heatmap, no error, no explanation. It also made a UI test fail on CI
        // with "heatmap did not render", which is true and unhelpful. Say why.
        guard let bundle = Self.modelDirectory else {
            scanState = .failed(Self.modelsMissingMessage)
            return
        }
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
                    modelURL: bundle.appending(path: Self.backboneName),
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

        // Numbering is gated on the motifs, so it is only attempted for a
        // sequence already identified as a family member.
        numbering = nil
        numberingScheme = nil
        pocketAnchors = []
        if let store = try? FamilyStore() {
            if let result = try? store.klifsNumbering(for: sequence) {
                numbering = result
                numberingScheme = "KLIFS"
                pocketAnchors = store.pocketAnchors(result, in: sequence)
            } else if let result = try? store.gpcrdbNumbering(for: sequence) {
                numbering = result
                numberingScheme = "GPCRdb"
            }
        }
        recomputeConstructs()
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
