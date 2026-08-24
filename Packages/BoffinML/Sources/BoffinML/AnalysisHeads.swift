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
public struct HeadPredictions: Sendable {
    /// Per-residue eight-state secondary structure.
    public let secondaryStructure: [SecondaryStructure]
    /// Per-residue probability of being disordered, 0 to 1.
    public let disorderProbability: [Double]
    /// The decision threshold the disorder head was calibrated with.
    public let disorderThreshold: Double

    /// Residues called disordered at the calibrated threshold.
    public var isDisordered: [Bool] {
        disorderProbability.map { $0 > disorderThreshold }
    }
}

/// Configuration exported alongside the trained heads.
struct HeadConfiguration: Decodable {
    let embedWidth: Int
    let headWidth: Int
    let disorderThreshold: Double

    enum CodingKeys: String, CodingKey {
        case embedWidth = "embed_width"
        case headWidth = "head_width"
        case disorderThreshold = "disorder_threshold"
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
    private var compiled: [URL: URL] = [:]

    private let logger = Logger(subsystem: "com.marcdeller.boffin", category: "AnalysisHeads")

    /// - Parameter directory: the folder holding `secondary_structure.mlpackage`,
    ///   `disorder.mlpackage` and `config.json`.
    /// - Throws: ``HeadError/unavailable(_:)`` when the configuration cannot be
    ///   read. Models load lazily, so a missing model surfaces at ``predict(for:)``.
    public init(directory: URL) throws {
        self.secondaryStructureURL = directory.appending(path: "secondary_structure.mlpackage")
        self.disorderURL = directory.appending(path: "disorder.mlpackage")
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
                disorderThreshold: configuration.disorderThreshold)
        }

        let window = Self.headWindow
        var structureLogits: [[Double]] = []
        var disorderLogits: [[Double]] = []
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

        return HeadPredictions(
            secondaryStructure: structure,
            disorderProbability: disorderProbability,
            disorderThreshold: configuration.disorderThreshold)
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

        input.withUnsafeMutableBytes { raw, strides in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
            // Zero first: anything past the real residues is padding, and stale
            // memory there would be read as a real embedding.
            for index in 0..<(width * window) { base[index] = 0 }
            for (position, vector) in vectors.enumerated() {
                for channel in 0..<min(width, vector.count) {
                    base[channel * window + position] = Float16(vector[channel])
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
        logits.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: Float16.self)
            for position in 0..<vectors.count {
                var row = [Double](repeating: 0, count: classes)
                for klass in 0..<classes {
                    row[klass] = Double(base[klass * window + position])
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

    /// Every model-derived track, in display order.
    public func tracks() -> [AnyResidueTrack] {
        var result = [secondaryStructureTrack(), disorderTrack()]
        if let spans = disorderSpansTrack() { result.append(spans) }
        return result
    }
}
