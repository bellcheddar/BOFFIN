//  EmbeddingEngine.swift
//  BoffinML
//
//  Invariant 1 of the build plan: one forward pass, four fan-outs.
//
//  Every analytical feature in BOFFIN reads from a single ESM-2 pass on the
//  Neural Engine. Per-residue hidden states drive order and boundaries,
//  masked-token logits drive fitness, and the mean-pooled embedding drives
//  family and homolog search. Do not build independent pipelines per feature:
//  the expensive step is amortised across the whole app, and that amortisation
//  is the reason the app is viable on a phone at all.
//
//  Measured for esm2_t12_35M_UR50D on 2026-08-24: 98.8% of executable
//  operations planned for the Neural Engine, 746 of 755. See Docs/perf-log.md.

import BoffinCore
import CoreML
import Foundation
import OSLog

/// Sequence-length buckets for the Neural Engine.
///
/// The ANE will not accept fully dynamic sequence lengths, so the converted
/// model declares `EnumeratedShapes` over these token counts. A sequence is
/// padded up to the smallest fitting bucket, the padding is masked, and the
/// output is sliced back. Sequences longer than the largest bucket are tiled
/// with overlap and stitched.
public enum ShapeBucket: Int, CaseIterable, Sendable, Comparable, Codable {
    case tokens128 = 128
    case tokens256 = 256
    case tokens384 = 384
    case tokens512 = 512
    case tokens768 = 768
    case tokens1024 = 1024

    /// Residue overlap between tiles when a sequence exceeds the largest bucket.
    /// Overlapping positions are averaged when stitching.
    public static let tileOverlap = 128

    public static func < (lhs: ShapeBucket, rhs: ShapeBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The smallest bucket that fits `tokenCount`, or `nil` if tiling is needed.
    public static func smallestFitting(tokenCount: Int) -> ShapeBucket? {
        allCases.first { $0.rawValue >= tokenCount }
    }
}

/// The output of one pass, and the three tensors the app fans out from.
public struct EmbeddingResult: Sendable {
    /// Per-residue hidden states, aligned one-to-one with the sequence.
    public let hiddenStates: [[Float]]

    /// Mean-pooled embedding over real residues (special tokens and padding
    /// excluded, since pooling over pad tokens dilutes the vector towards
    /// whatever the model does with nothing).
    public let pooled: [Float]

    /// Hidden dimension.
    public var width: Int { pooled.count }

    /// How many inference passes this took. More than one means the sequence
    /// was tiled.
    public let passes: Int

    public init(hiddenStates: [[Float]], pooled: [Float], passes: Int) {
        self.hiddenStates = hiddenStates
        self.pooled = pooled
        self.passes = passes
    }
}

public enum EmbeddingError: Error, Sendable {
    case modelUnavailable(String)
    case tokeniserUnavailable(String)
    case emptySequence
    case unexpectedOutputShape(String)
    case tilingFailed
}

/// The single point of access to the backbone.
///
/// Core ML models are not thread-safe under concurrent prediction, so all
/// traffic is serialised through this actor.
public actor EmbeddingEngine {

    private let modelURL: URL
    private let tokeniser: Tokeniser
    private var model: MLModel?
    private var compiledURL: URL?
    private let scoringModelURL: URL?
    private var scoringModel: MLModel?
    private var scoringCompiledURL: URL?
    /// Set once the scoring model has been tried and found unusable, so a
    /// missing or broken second model costs one failed load rather than one
    /// per batch of a 300-position scan.
    private var scoringModelUnavailable = false

    private var cache: [String: EmbeddingResult] = [:]
    private let cacheLimit: Int
    private let logger = Logger(subsystem: "com.marcdeller.boffin", category: "EmbeddingEngine")

    /// - Parameters:
    ///   - modelURL: a compiled `.mlmodelc` or an `.mlpackage`.
    ///   - tokeniserURL: the JSON exported alongside the model.
    ///   - scoringModelURL: an optional second model, traced at a fixed batch
    ///     and a fixed length, used only by the masked-marginal scan. Absent,
    ///     everything still works and the scan runs a row at a time.
    ///   - cacheLimit: how many results to retain, keyed by sequence.
    /// - Throws: ``EmbeddingError/tokeniserUnavailable(_:)`` when the alphabet
    ///   cannot be read. The model itself is loaded lazily on first use, so a
    ///   missing model surfaces at ``embed(_:)`` rather than here.
    public init(
        modelURL: URL, tokeniserURL: URL, scoringModelURL: URL? = nil,
        cacheLimit: Int = 16
    ) throws {
        self.modelURL = modelURL
        self.scoringModelURL = scoringModelURL
        self.cacheLimit = cacheLimit
        do {
            self.tokeniser = try Tokeniser(contentsOf: tokeniserURL)
        } catch {
            throw EmbeddingError.tokeniserUnavailable(
                "\(tokeniserURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func loadedModel() async throws -> MLModel {
        if let model { return model }

        // `MLModel(contentsOf:)` takes a COMPILED model. Handed an .mlpackage it
        // fails with "Unable to load model ... Compile the model with Xcode",
        // which is accurate but easy to read as "the model is broken". In the
        // shipping app the package is compiled at build time; in development and
        // in tests it is the raw conversion output, so compile it here and keep
        // the result for the life of the actor.
        let loadURL: URL
        if modelURL.pathExtension == "mlpackage" {
            if let compiled = compiledURL {
                loadURL = compiled
            } else {
                do {
                    let compiled = try await MLModel.compileModel(at: modelURL)
                    compiledURL = compiled
                    loadURL = compiled
                } catch {
                    throw EmbeddingError.modelUnavailable(
                        "could not compile \(modelURL.lastPathComponent): "
                            + error.localizedDescription)
                }
            }
        } else {
            loadURL = modelURL
        }

        let configuration = MLModelConfiguration()
        // Excluding the GPU deliberately. If an operation cannot run on the
        // Neural Engine it falls back to the CPU and shows up in a benchmark,
        // rather than quietly landing on the GPU and looking acceptable while
        // defeating the premise of the app.
        configuration.computeUnits = .cpuAndNeuralEngine
        do {
            let loaded = try MLModel(contentsOf: loadURL, configuration: configuration)
            model = loaded
            return loaded
        } catch {
            throw EmbeddingError.modelUnavailable(error.localizedDescription)
        }
    }

    /// Drop cached embeddings, keeping the loaded model.
    ///
    /// The cache holds up to `cacheLimit` results and each one is a hidden
    /// state per residue, so a full cache of long sequences is tens of
    /// megabytes. It cost nothing before, because the app built a new engine
    /// for every analysis and the cache never outlived one; now that the
    /// engine is held for the app's lifetime the cache is real and worth
    /// giving back under pressure.
    ///
    /// The model itself is kept. Releasing it would mean paying the load and
    /// the first-prediction cost again, which is the cost `warmUp` exists to
    /// avoid, and the cached results are the larger and more replaceable half.
    /// How many results are cached. For tests: the cache is otherwise
    /// invisible, and a release that frees nothing looks identical to one that
    /// frees everything.
    var cachedCount: Int { cache.count }

    public func releaseUnderMemoryPressure() {
        let released = cache.count
        cache.removeAll(keepingCapacity: false)
        logger.info("released \(released) cached embeddings")
    }

    /// Pay the Neural Engine compilation cost with a dummy input.
    ///
    /// The first prediction after load is markedly slower than every subsequent
    /// one. Calling this at launch means the user never sees that cost attached
    /// to their own first sequence, where it would look like the app being slow
    /// at the thing it exists to do.
    public func warmUp() async {
        do {
            let model = try await loadedModel()
            let (tokens, _) = tokeniser.encode([], paddedTo: ShapeBucket.tokens128.rawValue)
            _ = try predict(model: model, tokens: tokens)
            logger.info("warm-up complete")
        } catch {
            logger.error("warm-up failed: \(String(describing: error))")
        }
    }

    /// Embed a sequence, tiling if it exceeds the largest bucket.
    public func embed(_ sequence: ProteinSequence) async throws -> EmbeddingResult {
        guard sequence.count > 0 else { throw EmbeddingError.emptySequence }

        let key = cacheKey(for: sequence)
        if let cached = cache[key] { return cached }

        let model = try await loadedModel()
        let plan = SequenceTiler.plan(
            residueCount: sequence.count, specialTokens: tokeniser.specialTokenCount)

        var outputs: [(range: Range<Int>, vectors: [[Float]])] = []
        for tile in plan.tiles {
            let residues = Array(sequence.residues[tile.residues])
            let (tokens, residueRange) = tokeniser.encode(
                residues, paddedTo: tile.bucket.rawValue)
            let hidden = try predict(model: model, tokens: tokens)
            let sliced = try slice(hidden, residueRange: residueRange, width: hidden.width)
            outputs.append((tile.residues, sliced))
        }

        guard
            let stitched = SequenceTiler.stitch(outputs, residueCount: sequence.count)
        else { throw EmbeddingError.tilingFailed }

        let result = EmbeddingResult(
            hiddenStates: stitched,
            pooled: meanPool(stitched),
            passes: plan.tiles.count)

        store(result, forKey: key)
        return result
    }

    // MARK: - Internals

    private struct HiddenTensor {
        let values: MLMultiArray
        let width: Int
    }

    private func predict(model: MLModel, tokens: [Int32]) throws -> HiddenTensor {
        let input = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        for (index, token) in tokens.enumerated() {
            input[index] = NSNumber(value: token)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: ["tokens": input])
        let output = try model.prediction(from: features)

        guard let hidden = output.featureValue(for: "hidden_states")?.multiArrayValue else {
            throw EmbeddingError.unexpectedOutputShape("hidden_states missing from model output")
        }
        guard hidden.shape.count == 3 else {
            throw EmbeddingError.unexpectedOutputShape(
                "expected rank 3 hidden states, got shape \(hidden.shape)")
        }
        return HiddenTensor(values: hidden, width: hidden.shape[2].intValue)
    }

    private func slice(
        _ tensor: HiddenTensor,
        residueRange: Range<Int>,
        width: Int
    ) throws -> [[Float]] {
        let sequenceLength = tensor.values.shape[1].intValue
        guard residueRange.upperBound <= sequenceLength else {
            throw EmbeddingError.unexpectedOutputShape(
                "residue range \(residueRange) exceeds model output length \(sequenceLength)")
        }

        var rows: [[Float]] = []
        rows.reserveCapacity(residueRange.count)

        // Read through raw bytes rather than `withUnsafeBufferPointer(ofType:)`:
        // Float16's MLShapedArrayScalar conformance is macOS 15+, and these
        // packages build for macOS 14 so their tests run on the host.
        //
        // Both float16 and float32 are handled rather than assuming the model's
        // declared output type. A model reconverted at a different precision
        // would otherwise be reinterpreted at the wrong element size, which does
        // not throw: it produces plausible-looking garbage embeddings.
        // Stride-aware, for the same reason as the logits reader: Core ML pads
        // rows and a dense `position * width` offset silently reads the wrong
        // values for every position after the first.
        let dataType = tensor.values.dataType
        let strides = tensor.values.strides.map(\.intValue)
        let positionStride = strides.count > 1 ? strides[1] : width
        let componentStride = strides.count > 2 ? strides[2] : 1

        tensor.values.withUnsafeBytes { raw in
            let read: (Int) -> Float
            switch dataType {
            case .float16:
                let typed = raw.bindMemory(to: Float16.self)
                read = { Float(typed[$0]) }
            case .float32:
                let typed = raw.bindMemory(to: Float.self)
                read = { typed[$0] }
            case .double:
                let typed = raw.bindMemory(to: Double.self)
                read = { Float(typed[$0]) }
            default:
                read = { _ in Float.nan }
            }
            for position in residueRange {
                let start = position * positionStride
                var row = [Float](repeating: 0, count: width)
                for component in 0..<width {
                    row[component] = read(start + component * componentStride)
                }
                rows.append(row)
            }
        }

        guard rows.count == residueRange.count else {
            throw EmbeddingError.unexpectedOutputShape(
                "unsupported hidden state element type \(dataType.rawValue)")
        }
        return rows
    }

    private func meanPool(_ vectors: [[Float]]) -> [Float] {
        guard let width = vectors.first?.count, !vectors.isEmpty else { return [] }
        var total = [Float](repeating: 0, count: width)
        for vector in vectors {
            for component in 0..<width { total[component] += vector[component] }
        }
        let divisor = Float(vectors.count)
        for component in 0..<width { total[component] /= divisor }
        return total
    }

    // MARK: - Scoring support

    /// Special tokens the tokeniser wraps around the residues.
    var tokeniserSpecialTokenCount: Int { tokeniser.specialTokenCount }

    /// Token index for a residue identity.
    func tokeniserIndex(for identity: ResidueIdentity) -> Int32 {
        tokeniser.index(for: identity)
    }

    /// Where a residue sits in the token buffer, past any prepended `<cls>`.
    func tokenOffset(for residue: Int) -> Int {
        residue + (tokeniser.prependBOS ? 1 : 0)
    }

    /// The model and batch size to score with, for a given bucket.
    ///
    /// The scoring model is traced at ONE batch and ONE length, so it is used
    /// only at that length and the backbone serves everything else. This is
    /// not a tuning choice: measured per variant, batch 8 beats batch 1 by
    /// 1.45x at 384 and loses to it by nearly three times at 128 and 256. A
    /// model traced at a fixed shape is fast at that shape and nowhere else.
    ///
    /// Because the shape is fixed rather than a range, Core ML refuses any
    /// other input outright instead of silently running the slow path, which
    /// is the reason for preferring `--flexible fixed` when converting it.
    func scoringPlan(for bucket: ShapeBucket) async throws -> (model: MLModel, rows: Int) {
        if bucket == Self.scoringBucket, !scoringModelUnavailable,
            let model = await loadedScoringModel()
        {
            return (model, Self.scoringBatchSize)
        }
        return (try await loadedModel(), 1)
    }

    private func loadedScoringModel() async -> MLModel? {
        if let scoringModel { return scoringModel }
        guard let scoringModelURL else {
            scoringModelUnavailable = true
            return nil
        }
        do {
            let loadURL: URL
            if scoringModelURL.pathExtension == "mlpackage" {
                if let compiled = scoringCompiledURL {
                    loadURL = compiled
                } else {
                    let compiled = try await MLModel.compileModel(at: scoringModelURL)
                    scoringCompiledURL = compiled
                    loadURL = compiled
                }
            } else {
                loadURL = scoringModelURL
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let loaded = try MLModel(contentsOf: loadURL, configuration: configuration)
            scoringModel = loaded
            logger.info("scoring model loaded")
            return loaded
        } catch {
            // Degrade rather than fail. The scan is correct at batch 1 and only
            // slower, so an absent or unreadable second model must not be the
            // difference between a fitness scan and an error.
            let detail = String(describing: error)
            logger.error("scoring model unavailable, scanning a row at a time: \(detail)")
            scoringModelUnavailable = true
            return nil
        }
    }

    func loadedModelForScoring() async throws -> MLModel {
        try await loadedModel()
    }

    /// Run the model with each named position masked, one batch row per
    /// position, and return the logit row at each masked position.
    ///
    /// An empty `positions` array means: run once over the unmasked sequence
    /// and return the logits for EVERY token. That is the wild-type marginal
    /// path, and it shares this code so the two modes cannot drift apart in
    /// how they tokenise or slice.
    func predictMasked(
        model: MLModel,
        sequence: ProteinSequence,
        positions: [Int],
        bucket: ShapeBucket,
        batchRows: Int? = nil
    ) throws -> [[Float]] {
        let width = bucket.rawValue
        let (baseTokens, _) = tokeniser.encode(sequence.residues, paddedTo: width)

        // The scoring model's batch is FIXED, so the last chunk of a scan has
        // to be padded up to it rather than sent short. The padding rows carry
        // the unmasked sequence and their outputs are never read: `positions`
        // is what the rows are indexed by below.
        let rowCount = max(batchRows ?? positions.count, max(positions.count, 1))
        let input = try MLMultiArray(
            shape: [NSNumber(value: rowCount), NSNumber(value: width)], dataType: .int32)

        // Filled by subscript, matching the embedding path. The
        // `withUnsafeMutableBufferPointer(ofType:)` form compiles and does NOT
        // populate the array here, so every token stayed 0 (`<cls>`): the model
        // then saw a buffer of start-tokens, returned near-identical logits at
        // every position, and the delta-LLR matrix came out as a plausible-
        // looking field in which 29% of substitutions beat the wild type of one
        // of the most conserved proteins known. Nothing errored.
        for row in 0..<rowCount {
            for column in 0..<width {
                input[row * width + column] = NSNumber(value: baseTokens[column])
            }
            // Mask exactly the position this row is asking about. The rest of
            // the sequence stays intact: that context is the whole point.
            if row < positions.count {
                input[row * width + tokenOffset(for: positions[row])] =
                    NSNumber(value: tokeniser.maskIndex)
            }
        }

        let features = try MLDictionaryFeatureProvider(dictionary: ["tokens": input])
        let output = try model.prediction(from: features)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw ScoringError.unexpectedOutputShape(
                "logits missing from model output: the backbone must be converted with "
                    + "a logits output for scoring to work")
        }
        guard logits.shape.count == 3 else {
            throw ScoringError.unexpectedOutputShape(
                "expected rank 3 logits, got shape \(logits.shape)")
        }
        let vocabulary = logits.shape[2].intValue

        // Read according to the ACTUAL element type, not the declared one.
        // Reading float32 storage as Float16 does not fail: it returns numbers,
        // and they look like plausible logits. The first version assumed
        // Float16 here and produced a delta-LLR matrix in which 29% of
        // substitutions beat the wild type, for one of the most conserved
        // proteins known, and it rendered perfectly.
        let dataType = logits.dataType
        var rows: [[Float]] = []

        // Index through the array's OWN strides. Core ML pads rows for
        // alignment, so a (1, S, 33) logits array is not densely packed: the
        // stride between tokens is larger than 33. Computing offsets as
        // `token * vocabulary` reads part of the previous token's padding and
        // part of the real row, which returns a shifted vector of real-looking
        // logits. Token 0 comes out correct (its offset is zero) and every
        // other token is quietly wrong, which is exactly the kind of error that
        // renders as a convincing heatmap.
        let strides = logits.strides.map(\.intValue)
        let batchStride = strides.count > 0 ? strides[0] : width * vocabulary
        let tokenStride = strides.count > 1 ? strides[1] : vocabulary
        let valueStride = strides.count > 2 ? strides[2] : 1

        func readRow(_ token: Int, _ batchRow: Int, _ base: (Int) -> Float) -> [Float] {
            var row = [Float](repeating: 0, count: vocabulary)
            let offset = batchRow * batchStride + token * tokenStride
            for index in 0..<vocabulary { row[index] = base(offset + index * valueStride) }
            return row
        }

        logits.withUnsafeBytes { raw in
            let read: (Int) -> Float
            switch dataType {
            case .float16:
                let typed = raw.bindMemory(to: Float16.self)
                read = { Float(typed[$0]) }
            case .float32:
                let typed = raw.bindMemory(to: Float.self)
                read = { typed[$0] }
            case .double:
                let typed = raw.bindMemory(to: Double.self)
                read = { Float(typed[$0]) }
            default:
                read = { _ in Float.nan }
            }

            if positions.isEmpty {
                // Wild-type marginal: every token's row from the single pass.
                rows.reserveCapacity(width)
                for token in 0..<width { rows.append(readRow(token, 0, read)) }
            } else {
                rows.reserveCapacity(positions.count)
                for (rowIndex, position) in positions.enumerated() {
                    rows.append(readRow(tokenOffset(for: position), rowIndex, read))
                }
            }
        }

        if rows.first?.contains(where: { $0.isNaN }) == true {
            throw ScoringError.unexpectedOutputShape(
                "unsupported logits element type \(dataType.rawValue)")
        }
        return rows
    }

    private func cacheKey(for sequence: ProteinSequence) -> String {
        // The letters are the input the model actually sees, so two sequences
        // with different names but identical residues share a result.
        sequence.letters
    }

    private func store(_ result: EmbeddingResult, forKey key: String) {
        if cache.count >= cacheLimit, let victim = cache.keys.first {
            cache.removeValue(forKey: victim)
        }
        cache[key] = result
    }
}
