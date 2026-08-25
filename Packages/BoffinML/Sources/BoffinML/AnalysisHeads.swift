//  AnalysisHeads.swift
//  BoffinML
//
//  The Order tab's model-derived tracks: secondary structure and disorder.
//
//  Invariant 1 in practice. These heads consume the hidden states from the
//  single backbone pass rather than running the backbone again, which is what
//  makes stacking more tracks cheap: each head is 0.63 MB and 0.26 ms against
//  the backbone's 31 ms, so a fourth and fifth track cost almost nothing.
//
//  Measured accuracy, and the honest shape of it, is in Docs/perf-log.md. The
//  short version: secondary structure is dependable, disorder is dependable on
//  proteins with relatives in the PDB and weak on novel folds. That asymmetry
//  is surfaced to the user rather than averaged away.

import BoffinCore
import CoreML
import Foundation
import OSLog

/// Eight-state secondary structure, in the order the head emits.
///
/// The order is not alphabetical and is not a choice: it is the column order of
/// the training labels, so changing it silently relabels every prediction.
public enum SecondaryStructure: Int, CaseIterable, Sendable, Codable {
    case threeTenHelix = 0  // G
    case alphaHelix = 1  // H
    case piHelix = 2  // I
    case betaBridge = 3  // B
    case betaStrand = 4  // E
    case bend = 5  // S
    case turn = 6  // T
    case coil = 7  // C

    /// DSSP single-letter code.
    public var code: String {
        switch self {
        case .threeTenHelix: "G"
        case .alphaHelix: "H"
        case .piHelix: "I"
        case .betaBridge: "B"
        case .betaStrand: "E"
        case .bend: "S"
        case .turn: "T"
        case .coil: "C"
        }
    }

    public var name: String {
        switch self {
        case .threeTenHelix: "3-10 helix"
        case .alphaHelix: "Alpha helix"
        case .piHelix: "Pi helix"
        case .betaBridge: "Beta bridge"
        case .betaStrand: "Beta strand"
        case .bend: "Bend"
        case .turn: "Turn"
        case .coil: "Coil"
        }
    }

    /// The standard three-state collapse: G/H/I helix, B/E strand, S/T/C coil.
    public var threeState: String {
        switch self {
        case .threeTenHelix, .alphaHelix, .piHelix: "H"
        case .betaBridge, .betaStrand: "E"
        case .bend, .turn, .coil: "C"
        }
    }
}

/// What the heads produced for one sequence.
/// Membrane topology, in the order the head emits.
///
/// Three classes, and intramembrane regions are deliberately not one of them:
/// they were masked out of the training loss rather than folded into either
/// neighbour, because a re-entrant loop dips into the bilayer without crossing
/// it and calling it either way teaches the head something false about where a
/// span ends.
public enum TopologyClass: Int, CaseIterable, Sendable, Codable {
    case outside = 0
    case transmembrane = 1
    case signalPeptide = 2

    public var name: String {
        switch self {
        case .outside: "Outside"
        case .transmembrane: "Transmembrane"
        case .signalPeptide: "Signal peptide"
        }
    }

    public var code: String {
        switch self {
        case .outside: "o"
        case .transmembrane: "M"
        case .signalPeptide: "S"
        }
    }
}

/// A contiguous run of one topology class.
public struct TopologySpan: Sendable, Hashable, Identifiable {
    public let kind: TopologyClass
    /// Zero-based residue indices, inclusive.
    public let range: ClosedRange<Int>

    public var id: String { "\(kind.rawValue)-\(range.lowerBound)" }
    public var length: Int { range.count }
}

public struct HeadPredictions: Sendable {
    /// Per-residue eight-state secondary structure.
    public let secondaryStructure: [SecondaryStructure]
    /// Per-residue probability of being disordered, 0 to 1.
    public let disorderProbability: [Double]
    /// The decision threshold the disorder head was calibrated with.
    public let disorderThreshold: Double
    /// Gaps of at most this many residues are closed before filtering.
    public let topologyMergeGap: Int
    /// Spans shorter than this are dropped.
    public let topologyMinimumSpan: Int
    /// Per-residue membrane topology, absent when the head is not bundled.
    ///
    /// Optional rather than defaulted to `.outside` everywhere: "no prediction"
    /// and "predicted soluble" are different claims, and the Boundary tab treats
    /// them differently. A construct solver that cannot see TM spans must refuse
    /// to enforce the constraint rather than assume there is nothing to enforce.
    public let topology: [TopologyClass]?

    public init(
        secondaryStructure: [SecondaryStructure],
        disorderProbability: [Double],
        disorderThreshold: Double,
        topology: [TopologyClass]? = nil,
        topologyMergeGap: Int = HeadPredictions.defaultMergeGap,
        topologyMinimumSpan: Int = HeadPredictions.defaultMinimumSpan
    ) {
        self.secondaryStructure = secondaryStructure
        self.disorderProbability = disorderProbability
        self.disorderThreshold = disorderThreshold
        self.topology = topology
        self.topologyMergeGap = topologyMergeGap
        self.topologyMinimumSpan = topologyMinimumSpan
    }

    /// Residues called disordered at the calibrated threshold.
    public var isDisordered: [Bool] {
        disorderProbability.map { $0 > disorderThreshold }
    }

    /// Contiguous runs of transmembrane and signal-peptide residues, merged
    /// across short gaps and then filtered by length.
    ///
    /// The default gap is ZERO, and that is a measurement rather than an
    /// oversight.
    ///
    /// Raw per-residue argmax held span precision at 0.60 while per-residue F1
    /// was 0.886, and the obvious explanation is fragmentation: a single helix
    /// broken in the middle by a few stray residues, scored as two wrong spans
    /// instead of one right one. Merging short gaps is the obvious fix. Swept on
    /// the validation split, it is the wrong one:
    ///
    ///     gap 0, min 18   recall 0.819   precision 0.852   F1 0.835
    ///     gap 2, min 18   recall 0.767   precision 0.802   F1 0.784
    ///     gap 4, min 18   recall 0.691   precision 0.756   F1 0.722
    ///     gap 8, min 15   recall 0.515   precision 0.650   F1 0.575
    ///
    /// Merging costs recall at every gap, because in a multi-pass membrane
    /// protein adjacent helices are separated by short loops: closing a gap of
    /// four fuses two genuine helices and destroys both. The low precision was
    /// short spurious spans, not split real ones, and the LENGTH FILTER removes
    /// those for almost nothing (recall 0.841 to 0.819, precision 0.600 to
    /// 0.852).
    ///
    /// The gap parameter is kept because it is worth being able to reproduce
    /// that, and because the order matters if it is ever non-zero: filtering
    /// first would delete the fragments a merge would have rejoined.
    ///
    /// - Parameters:
    ///   - mergeGap: gaps of at most this many residues between two runs of the
    ///     same class are closed.
    ///   - minimumSpan: runs shorter than this are dropped afterwards. A
    ///     bilayer is about 30 A, which takes roughly 20 residues of helix to
    ///     cross, so a three-residue "span" is noise. It matters because the
    ///     Boundary tab turns every span into a hard constraint and a spurious
    ///     one forbids a cut site that is perfectly good.
    /// - Returns: spans in ascending order.
    public func topologySpans(
        mergeGap: Int? = nil, minimumSpan: Int? = nil
    ) -> [TopologySpan] {
        let mergeGap = mergeGap ?? topologyMergeGap
        let minimumSpan = minimumSpan ?? topologyMinimumSpan
        guard let topology else { return [] }

        var runs: [(kind: TopologyClass, start: Int, end: Int)] = []
        var index = 0
        while index < topology.count {
            let kind = topology[index]
            var end = index
            while end + 1 < topology.count, topology[end + 1] == kind { end += 1 }
            if kind != .outside { runs.append((kind, index, end)) }
            index = end + 1
        }

        var merged: [(kind: TopologyClass, start: Int, end: Int)] = []
        for run in runs {
            if var last = merged.last, last.kind == run.kind,
                run.start - last.end - 1 <= mergeGap
            {
                last.end = run.end
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }

        return
            merged
            .filter { $0.end - $0.start + 1 >= minimumSpan }
            .map { TopologySpan(kind: $0.kind, range: $0.start...$0.end) }
    }

    /// Swept on the validation split, not chosen: see `train_topology_head.py`.
    public static let defaultMergeGap = 0
    public static let defaultMinimumSpan = 18

    /// How many membrane-spanning segments were predicted.
    public func transmembraneSpanCount(
        mergeGap: Int? = nil, minimumSpan: Int? = nil
    ) -> Int {
        topologySpans(mergeGap: mergeGap, minimumSpan: minimumSpan)
            .count { $0.kind == .transmembrane }
    }
}

/// Configuration exported alongside the trained heads.
struct HeadConfiguration: Decodable {
    let embedWidth: Int
    let headWidth: Int
    let disorderThreshold: Double
    /// Span post-processing, swept on the validation split by
    /// `train_topology_head.py` and written here so the Swift side cannot drift
    /// from the sweep that chose them. `CLAUDE.md` records two constants that
    /// already had to be kept in step by hand and failed only at runtime; this
    /// is the same hazard, so it is published rather than duplicated.
    let topologyMergeGap: Int?
    let topologyMinimumSpan: Int?

    enum CodingKeys: String, CodingKey {
        case embedWidth = "embed_width"
        case headWidth = "head_width"
        case disorderThreshold = "disorder_threshold"
        case topologyMergeGap = "topology_merge_gap"
        case topologyMinimumSpan = "topology_minimum_span"
    }
}

public enum HeadError: Error, Sendable {
    case unavailable(String)
    case unexpectedOutputShape(String)
    case lengthMismatch(expected: Int, found: Int)
}

/// Runs the analysis heads over hidden states from the backbone.
///
/// Serialised as an actor for the same reason as `EmbeddingEngine`: Core ML
/// models are not thread-safe under concurrent prediction.
public actor AnalysisHeads {

    /// The fixed window the heads are converted for.
    ///
    /// MUST match `--bucket` in `Tools/coreml/convert_heads.py`. A mismatch
    /// builds, converts and passes parity, then fails only at runtime with a
    /// shape error. `EnumeratedShapes` would remove the coupling and cannot be
    /// used: those models convert and save, then crash the process on predict.
    ///
    /// The implied zero padding is harmless, and that was measured rather than
    /// assumed: a 128 window and a 1024 window agree on 100% of argmax calls
    /// for ubiquitin, including the final 16 residues.
    static let headWindow = ShapeBucket.tokens1024.rawValue

    private let secondaryStructureURL: URL
    private let disorderURL: URL
    private let configuration: HeadConfiguration

    private var secondaryStructureModel: MLModel?
    private var disorderModel: MLModel?
    private var familyModel: MLModel?
    private let familyURL: URL
    private var topologyModel: MLModel?
    private let topologyURL: URL
    private let familyLabels: [String]?
    private let familyTemperature: Double
    private let familyTop1: Double
    private let familyCentroids: [[Double]]
    private let familySimilarityFloor: Double
    private let openSet: OpenSetModel?
    private var compiled: [URL: URL] = [:]

    private let logger = Logger(subsystem: "com.marcdeller.boffin", category: "AnalysisHeads")

    /// - Parameter directory: the folder holding `secondary_structure.mlpackage`,
    ///   `disorder.mlpackage` and `config.json`.
    /// - Throws: ``HeadError/unavailable(_:)`` when the configuration cannot be
    ///   read. Models load lazily, so a missing model surfaces at ``predict(for:)``.
    public init(directory: URL) throws {
        self.secondaryStructureURL = directory.appending(path: "secondary_structure.mlpackage")
        self.disorderURL = directory.appending(path: "disorder.mlpackage")
        self.familyURL = directory.appending(path: "family.mlpackage")
        self.topologyURL = directory.appending(path: "topology.mlpackage")

        // The family classifier is optional: the Order tab works without it, so
        // a missing one degrades rather than blocking.
        struct FamilyMetadata: Decodable {
            let families: [String]
            let temperature: Double
            let top1: Double
            let centroids: [[Double]]?
            let similarityFloor: Double?

            enum CodingKeys: String, CodingKey {
                case families, temperature, top1, centroids
                case similarityFloor = "similarity_floor"
            }
        }
        let metadata = try? JSONDecoder().decode(
            FamilyMetadata.self,
            from: Data(contentsOf: directory.appending(path: "family_labels.json")))
        self.familyLabels = metadata?.families
        self.familyTemperature = metadata?.temperature ?? 1.0
        self.familyTop1 = metadata?.top1 ?? 0
        self.familyCentroids = metadata?.centroids ?? []
        self.familySimilarityFloor = metadata?.similarityFloor ?? 0
        // Optional, like the classifier itself: without it the app falls back
        // to the cosine, which was measured as the weaker score but is better
        // than nothing and needs no extra asset.
        self.openSet = OpenSetModel(
            contentsOf: directory.appending(path: "family_openset.bin"))
        do {
            let data = try Data(contentsOf: directory.appending(path: "config.json"))
            self.configuration = try JSONDecoder().decode(HeadConfiguration.self, from: data)
        } catch {
            throw HeadError.unavailable("head config.json: \(error.localizedDescription)")
        }
    }

    /// The calibrated disorder threshold, tuned on validation data.
    public var disorderThreshold: Double { configuration.disorderThreshold }

    // Two dedicated loaders rather than one taking `inout`: actor-isolated
    // state cannot cross an await as an inout argument, because the actor may
    // service other work while the compile is in flight and the exclusive
    // borrow could not be upheld.
    private func secondaryStructureHead() async throws -> MLModel {
        if let secondaryStructureModel { return secondaryStructureModel }
        let loaded = try await load(url: secondaryStructureURL)
        secondaryStructureModel = loaded
        return loaded
    }

    private func disorderHead() async throws -> MLModel {
        if let disorderModel { return disorderModel }
        let loaded = try await load(url: disorderURL)
        disorderModel = loaded
        return loaded
    }

    private func familyHead() async throws -> MLModel {
        if let familyModel { return familyModel }
        let loaded = try await load(url: familyURL)
        familyModel = loaded
        return loaded
    }

    /// The topology head, or `nil` when it is not bundled.
    ///
    /// Unlike the other three this one is OPTIONAL, because it arrived after
    /// them and a bundle without it must still produce secondary structure and
    /// disorder rather than failing wholesale.
    private func topologyHead() async -> MLModel? {
        if let topologyModel { return topologyModel }
        guard FileManager.default.fileExists(atPath: topologyURL.path) else { return nil }
        guard let loaded = try? await load(url: topologyURL) else { return nil }
        topologyModel = loaded
        return loaded
    }

    /// Force the synchronous prediction overload.
    ///
    /// In an async context Swift prefers `prediction(from:) async`, which wants
    /// to send the model across an isolation boundary and is refused under
    /// strict concurrency. The actor already serialises access, which is the
    /// guarantee Core ML actually needs.
    private nonisolated func predictSynchronously(
        model: MLModel, features: MLFeatureProvider
    ) throws -> MLFeatureProvider {
        try model.prediction(from: features)
    }

    private func load(url: URL) async throws -> MLModel {
        let loadURL: URL
        if url.pathExtension == "mlpackage" {
            if let existing = compiled[url] {
                loadURL = existing
            } else {
                do {
                    let result = try await MLModel.compileModel(at: url)
                    compiled[url] = result
                    loadURL = result
                } catch {
                    throw HeadError.unavailable(
                        "could not compile \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } else {
            loadURL = url
        }

        let settings = MLModelConfiguration()
        settings.computeUnits = .cpuAndNeuralEngine
        do {
            return try MLModel(contentsOf: loadURL, configuration: settings)
        } catch {
            throw HeadError.unavailable(error.localizedDescription)
        }
    }

    /// Run both heads over one embedding result.
    public func predict(for embedding: EmbeddingResult) async throws -> HeadPredictions {
        let residueCount = embedding.hiddenStates.count
        guard residueCount > 0 else {
            return HeadPredictions(
                secondaryStructure: [], disorderProbability: [],
                disorderThreshold: configuration.disorderThreshold, topology: nil)
        }

        let window = Self.headWindow
        var structureLogits: [[Double]] = []
        var disorderLogits: [[Double]] = []
        var topologyLogits: [[Double]] = []
        let topology = await topologyHead()
        structureLogits.reserveCapacity(residueCount)
        disorderLogits.reserveCapacity(residueCount)

        var start = 0
        while start < residueCount {
            let end = min(start + window, residueCount)
            let slice = Array(embedding.hiddenStates[start..<end])

            let structureModel = try await secondaryStructureHead()
            let disorder = try await disorderHead()

            structureLogits.append(
                contentsOf: try run(structureModel, on: slice, classes: 8, window: window))
            disorderLogits.append(
                contentsOf: try run(disorder, on: slice, classes: 2, window: window))
            if let topology {
                topologyLogits.append(
                    contentsOf: try run(topology, on: slice, classes: 3, window: window))
            }
            start = end
        }

        guard structureLogits.count == residueCount else {
            throw HeadError.lengthMismatch(
                expected: residueCount, found: structureLogits.count)
        }

        let structure = structureLogits.map { logits -> SecondaryStructure in
            let best = logits.enumerated().max { $0.element < $1.element }?.offset ?? 7
            return SecondaryStructure(rawValue: best) ?? .coil
        }

        // Index 0 is the disordered class, matching the training label order.
        let disorderProbability = disorderLogits.map { logits -> Double in
            let maximum = logits.max() ?? 0
            let exponentials = logits.map { Foundation.exp($0 - maximum) }
            let total = exponentials.reduce(0, +)
            return total > 0 ? exponentials[0] / total : 0
        }

        let topologyCalls: [TopologyClass]? =
            topologyLogits.count == residueCount
            ? topologyLogits.map { logits in
                let best = logits.enumerated().max { $0.element < $1.element }?.offset ?? 0
                return TopologyClass(rawValue: best) ?? .outside
            }
            : nil

        return HeadPredictions(
            secondaryStructure: structure,
            disorderProbability: disorderProbability,
            disorderThreshold: configuration.disorderThreshold,
            topology: topologyCalls,
            topologyMergeGap: configuration.topologyMergeGap
                ?? HeadPredictions.defaultMergeGap,
            topologyMinimumSpan: configuration.topologyMinimumSpan
                ?? HeadPredictions.defaultMinimumSpan)
    }

    private func run(
        _ model: MLModel, on vectors: [[Float]], classes: Int, window: Int
    ) throws -> [[Double]] {
        let width = configuration.embedWidth

        // Layout is (1, width, 1, window): the Neural Engine's preferred 4D
        // shape, and the shape the head was converted for.
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: width), 1, NSNumber(value: window)],
            dataType: .float16)

        // Index through the array's OWN strides, never `channel * window`.
        //
        // `MLMultiArray` is not densely packed: Core ML pads for alignment, and
        // the closure below is handed the strides precisely because they cannot
        // be assumed. This code used to compute the offset itself and ignore
        // them, which is the same mistake that produced a completely convincing
        // delta-LLR heatmap of garbage in Phase 4: channel 0 reads correctly
        // because its offset is zero, and every channel after it is silently
        // shifted.
        input.withUnsafeMutableBytes { raw, strides in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
            let channelStride = strides.count > 1 ? strides[1] : window
            let positionStride = strides.count > 3 ? strides[3] : 1
            // Zero first: anything past the real residues is padding, and stale
            // memory there would be read as a real embedding.
            for channel in 0..<width {
                let row = channel * channelStride
                for position in 0..<window { base[row + position * positionStride] = 0 }
            }
            for (position, vector) in vectors.enumerated() {
                let column = position * positionStride
                for channel in 0..<min(width, vector.count) {
                    base[channel * channelStride + column] = Float16(vector[channel])
                }
            }
        }

        let features = try MLDictionaryFeatureProvider(dictionary: ["embeddings": input])
        let output = try model.prediction(from: features)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw HeadError.unexpectedOutputShape("logits missing from head output")
        }

        var rows: [[Double]] = []
        rows.reserveCapacity(vectors.count)
        // Same rule on the way out. The output is (1, classes, 1, window) and
        // its row stride is whatever Core ML chose, not `window`.
        let outputStrides = logits.strides.map(\.intValue)
        let classStride = outputStrides.count > 1 ? outputStrides[1] : window
        let positionStride = outputStrides.count > 3 ? outputStrides[3] : 1
        logits.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: Float16.self)
            for position in 0..<vectors.count {
                var row = [Double](repeating: 0, count: classes)
                let column = position * positionStride
                for klass in 0..<classes {
                    row[klass] = Double(base[klass * classStride + column])
                }
                rows.append(row)
            }
        }
        return rows
    }
}

// MARK: - ResidueTracks

extension HeadPredictions {

    /// Secondary structure as a categorical track on the shared ruler.
    ///
    /// Invariant 2: a model-derived output is the same kind of thing as an
    /// analytical one, so it stacks on the same ruler rather than getting its
    /// own view.
    public func secondaryStructureTrack() -> AnyResidueTrack {
        AnyResidueTrack(
            id: TrackID("secondary-structure"),
            title: "Secondary structure (SS8)",
            kind: .categorical,
            values: .categorical(secondaryStructure.map(\.code)),
            colourScheme: .categorical)
    }

    /// Disorder probability as a continuous track.
    ///
    /// The title carries the threshold because the number on screen is
    /// meaningless without it: this head is calibrated to call disorder only
    /// when confident, and a reader who assumes 0.5 will misread every value.
    public func disorderTrack() -> AnyResidueTrack {
        AnyResidueTrack(
            id: TrackID("disorder"),
            title: String(
                format: "Disorder probability (called above %.2f)", disorderThreshold),
            kind: .continuous,
            values: .continuous(disorderProbability.map { $0 }),
            colourScheme: .sequential(min: 0, max: 1))
    }

    /// Contiguous runs called disordered, as spans.
    public func disorderSpansTrack() -> AnyResidueTrack? {
        var spans: [TrackSpan] = []
        var runStart: Int?
        let called = isDisordered

        for index in called.indices {
            if called[index] {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                spans.append(TrackSpan(start: start, end: index - 1, label: "disordered"))
                runStart = nil
            }
        }
        if let start = runStart {
            spans.append(TrackSpan(start: start, end: called.count - 1, label: "disordered"))
        }

        guard !spans.isEmpty else { return nil }
        return AnyResidueTrack(
            id: TrackID("disorder-spans"),
            title: "Predicted disordered regions",
            kind: .span,
            values: .spans(spans),
            colourScheme: .solid)
    }

    /// Membrane topology as spans on the shared ruler.
    ///
    /// Spans rather than a per-residue categorical track, because what a reader
    /// needs from this is "there are seven of them, here" rather than the class
    /// of residue 212. Returns `nil` when the head is absent, so the ruler shows
    /// no row at all rather than a row of "outside" that looks like a
    /// prediction.
    public func topologyTrack(
        mergeGap: Int? = nil, minimumSpan: Int? = nil
    ) -> AnyResidueTrack? {
        guard topology != nil else { return nil }
        let spans = topologySpans(mergeGap: mergeGap, minimumSpan: minimumSpan)
        guard !spans.isEmpty else { return nil }
        let transmembrane = spans.count { $0.kind == .transmembrane }
        return AnyResidueTrack(
            id: TrackID("topology"),
            title: transmembrane > 0
                ? "Predicted topology: \(transmembrane) transmembrane "
                    + (transmembrane == 1 ? "span" : "spans")
                : "Predicted topology",
            kind: .span,
            values: .spans(
                spans.map {
                    TrackSpan(
                        start: $0.range.lowerBound, end: $0.range.upperBound,
                        label: $0.kind.name.lowercased())
                }),
            colourScheme: .categorical)
    }

    /// Every model-derived track, in display order.
    public func tracks() -> [AnyResidueTrack] {
        var result = [secondaryStructureTrack(), disorderTrack()]
        if let spans = disorderSpansTrack() { result.append(spans) }
        if let topology = topologyTrack() { result.append(topology) }
        return result
    }
}

// MARK: - Family classification

/// A ranked family call with its calibrated confidence.
public struct FamilyCall: Sendable, Hashable, Identifiable {
    public let accession: String
    public let confidence: Double
    public var id: String { accession }
}

/// What the classifier concluded.
public struct FamilyClassification: Sendable {
    /// Ranked calls, most confident first.
    public let ranked: [FamilyCall]
    /// Whether the top call clears the confidence floor.
    public let isConfident: Bool
    /// Held-out accuracy of the model that produced this, so the number on
    /// screen can be read against how often the model is right.
    public let top1Accuracy: Double

    /// Cosine similarity to the nearest training family's centroid.
    public let similarityToNearestFamily: Double

    /// Whether that similarity sits inside the range the model was trained on.
    public let isInDistribution: Bool

    /// How many families the classifier can answer with.
    public let familyCount: Int

    /// Squared Mahalanobis distance to the nearest training family, when the
    /// open-set asset is bundled.
    public let openSetDistance: Double?

    /// The distance above which a protein is called out of distribution.
    public let openSetThreshold: Double?

    /// The measured fraction of genuinely unseen families this catches.
    ///
    /// Carried alongside the verdict so the UI can state what the warning is
    /// worth. A flag with no measured reliability invites a reader to treat its
    /// silence as an all-clear, and here silence is wrong one time in five.
    public let openSetDetectionRate: Double?

    /// What the open-set flag is measured to catch, at the shipped threshold.
    ///
    /// From `Tools/heads/openset_experiment.py`, holding out whole families:
    /// 0.805 +/- 0.017. Stated rather than rounded to "most", because one
    /// unseen protein in five is still missed and a reader is entitled to know
    /// that before trusting the absence of a warning.
    static let openSetDetectionRate = 0.805

    /// Below this, the call is presented as uncertain rather than as an answer.
    ///
    /// The risk register names classifier over-confidence explicitly. The
    /// model's calibration error is measured at under 0.01, so a reported 0.5
    /// really is about a coin flip, and presenting it as a family assignment
    /// would be the failure the register describes.
    public static let confidenceFloor = 0.50

    public var top: FamilyCall? { ranked.first }

    /// The classifier is CLOSED SET and this is the honest consequence.
    ///
    /// It can only answer with one of the families it was trained on, so a
    /// protein from any other family is assigned the nearest one and reported
    /// confidently. Measured: ubiquitin, whose family PF00240 is not in the
    /// trained set, is called PF00076 at 79.7%. Confidence cannot detect this,
    /// because the model genuinely is confident, so the limitation has to be
    /// stated rather than scored around.
    public var caveat: String {
        if !isInDistribution {
            return "This sequence sits outside the range the classifier was trained on, "
                + "so the call above is the nearest of \(familyCount) families rather than "
                + "an identification."
        }
        if !isConfident {
            return "Low confidence. This is not a family assignment."
        }
        // The closed-set caveat is shown even when everything looks fine, and
        // this is the sentence that matters most.
        //
        // The open-set check catches about four unseen proteins in five, which
        // means one in five reaches this branch wrongly: a confident call, no
        // warning, and a family the protein does not belong to. A reader who
        // takes the absence of a warning as an all-clear would be wrong that
        // often, so the rate is stated rather than implied.
        var text =
            "The classifier chooses among \(familyCount) Pfam families and cannot "
            + "report one outside them, so treat a confident call as \"the closest of "
            + "those\" rather than as an exhaustive answer."
        if let rate = openSetDetectionRate {
            text +=
                " A check for proteins from outside those families catches about "
                + "\(Int((rate * 100).rounded()))% of them, so this is a weaker "
                + "all-clear than it looks."
        }
        return text
    }
}

extension AnalysisHeads {

    /// Cosine similarity between a pooled embedding and the nearest class
    /// centroid.
    ///
    /// A weak signal, and labelled as such: correctly-classified CDK2 measures
    /// 0.829 while misclassified ubiquitin measures 0.864, so this does not
    /// separate right from wrong. It separates "inside the training
    /// distribution" from "outside it", which is a different and still useful
    /// question.
    func nearestFamilySimilarity(to pooled: [Float]) -> Double {
        guard !familyCentroids.isEmpty else { return 1 }
        let vector = pooled.map(Double.init)
        let norm = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return 0 }

        var best = -1.0
        for centroid in familyCentroids where centroid.count == vector.count {
            var dot = 0.0
            for index in vector.indices { dot += vector[index] * centroid[index] }
            best = max(best, dot / norm)
        }
        return best
    }

    /// Classify the pooled embedding into a Pfam family.
    ///
    /// Invariant 1's third fan-out: this reads the same forward pass that
    /// produced the per-residue tracks, rather than running the backbone again.
    public func classifyFamily(
        for embedding: EmbeddingResult
    ) async throws
        -> FamilyClassification
    {
        guard let families = familyLabels, !families.isEmpty else {
            throw HeadError.unavailable("family labels not bundled")
        }
        let model = try await familyHead()

        let input = try MLMultiArray(
            shape: [1, NSNumber(value: embedding.width)], dataType: .float16)
        // Float16 has no NSNumber initialiser: write through Float, which the
        // array converts on assignment.
        for (index, value) in embedding.pooled.enumerated() {
            input[index] = NSNumber(value: value)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: ["embedding": input])
        // The synchronous overload: this is already inside the actor, and the
        // async one requires the model to cross an isolation boundary.
        let output = try predictSynchronously(model: model, features: features)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw HeadError.unexpectedOutputShape("family logits missing")
        }

        // Stride-aware, like every other read: Core ML pads rows.
        let strides = logits.strides.map(\.intValue)
        let valueStride = strides.last ?? 1
        var raw = [Double](repeating: 0, count: families.count)
        logits.withUnsafeBytes { rawBuffer in
            switch logits.dataType {
            case .float16:
                let typed = rawBuffer.bindMemory(to: Float16.self)
                for index in raw.indices { raw[index] = Double(typed[index * valueStride]) }
            case .float32:
                let typed = rawBuffer.bindMemory(to: Float.self)
                for index in raw.indices { raw[index] = Double(typed[index * valueStride]) }
            default:
                break
            }
        }

        // Temperature is applied as stored. It is 1.0 when the head was already
        // well calibrated: scaling an already-calibrated head makes it worse,
        // and that was measured rather than assumed.
        let temperature = max(familyTemperature, 1e-6)
        let scaled = raw.map { $0 / temperature }
        let maximum = scaled.max() ?? 0
        let exponentials = scaled.map { Foundation.exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        let probabilities = total > 0 ? exponentials.map { $0 / total } : exponentials

        let ranked =
            zip(families, probabilities)
            .map { FamilyCall(accession: $0.0, confidence: $0.1) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)

        let similarity = nearestFamilySimilarity(to: embedding.pooled)

        // Open-set rejection.
        //
        // Mahalanobis distance in the embedding space, measured at AUROC 0.969
        // against 0.850 for the centroid cosine this replaces. Not a
        // replacement for saying the classifier is closed set: at the shipped
        // threshold it catches about four unseen proteins in five, so one in
        // five still gets a confident wrong family and the caveat stays.
        let distance = openSet?.distance(from: embedding.pooled)
        let outsideTrainingSet: Bool
        if let distance, let openSet {
            outsideTrainingSet = distance > openSet.threshold
        } else {
            // The old instrument, kept as the fallback rather than deleted:
            // some build without the asset is better served by a weak signal
            // than by none.
            outsideTrainingSet = similarity < familySimilarityFloor
        }

        return FamilyClassification(
            ranked: Array(ranked),
            isConfident: (ranked.first?.confidence ?? 0) >= FamilyClassification.confidenceFloor,
            top1Accuracy: familyTop1,
            similarityToNearestFamily: similarity,
            isInDistribution: !outsideTrainingSet,
            familyCount: families.count,
            openSetDistance: distance,
            openSetThreshold: openSet?.threshold,
            openSetDetectionRate: openSet == nil ? nil : FamilyClassification.openSetDetectionRate)
    }
}
