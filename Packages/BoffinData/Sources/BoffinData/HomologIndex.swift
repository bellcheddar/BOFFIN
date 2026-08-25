//  HomologIndex.swift
//  BoffinData
//
//  Homolog search over pooled ESM-2 embeddings of the PDB.
//
//  Invariant 1's fourth fan-out: the same pooled vector that drives family
//  classification is the query here, so searching costs nothing beyond the
//  forward pass that has already happened.
//
//  Whitening
//  ---------
//  Pooled language-model embeddings are anisotropic: two random proteins in this
//  index score a cosine of 0.848 on average and the 99.9th percentile of random
//  pairs is 0.980, while real homologues score 0.97 to 0.99. Everything useful
//  lives in a sliver of the range, and int8 quantisation of the raw vectors
//  destroyed a quarter of it: recall@10 measured 0.748 against exhaustive float
//  search, silently, with the surviving hits still looking plausible because a
//  protein's neighbours are mostly its own family.
//
//  So the index is whitened before quantisation (Mu and Viswanath, "All-but-the-
//  top", ICLR 2018): subtract the mean, remove the four dominant principal
//  directions. That took recall@10 to 0.966 and moved the null distribution from
//  a mean of 0.848 to 0.000. The mean and the components travel in the file, and
//  EVERY QUERY MUST BE PUT THROUGH THE SAME TRANSFORM: skipping it does not
//  error, it just ranks badly.
//
//  Brute force, on purpose
//  -----------------------
//  An approximate nearest-neighbour structure (HNSW, IVF, product quantisation)
//  is the reflex for a vector index, and at this size it would be a mistake. The
//  index is 72,421 vectors of 480 dimensions: one query is a 34.8 M multiply
//  and add, which Accelerate does in single-digit milliseconds against a 100 ms
//  budget. An ANN structure would buy latency the app does not need and pay for
//  it in recall that is silently imperfect, an index that has to be rebuilt to a
//  different recipe, and a failure mode ("the right answer was not in the
//  candidate list") that nobody can see. Exhaustive search returns the actual
//  nearest neighbours, and the answer is checkable by definition.

import Accelerate
import BoffinCore
import Foundation

/// One entry of the index, with its similarity to the query.
public struct HomologHit: Sendable, Hashable, Identifiable {
    public let accession: String
    public let pdb: String
    public let chain: String
    /// Resolution in angstroms, absent for methods that do not report one.
    public let resolution: Double?
    public let method: String
    public let residueCount: Int
    /// How many PDB entries exist for this accession, which is the size of the
    /// crystallisation precedent available for it.
    public let structureCount: Int
    public let title: String
    /// The representative chain's SEQRES sequence, one-letter coded.
    ///
    /// Carried so the caller can align against it. A hit without its sequence
    /// can only be reported as a cosine, and a cosine reads as a percentage
    /// identity to anyone who has ever run BLAST.
    public let sequence: String
    /// Cosine similarity between the pooled embeddings, in [-1, 1].
    ///
    /// NOT a sequence identity. Two proteins with the same fold and 15%
    /// identity can sit close together here, which is what makes the index
    /// worth having and also why this number must never be labelled
    /// "% identity". `HomologAlignment` computes the real one.
    public let similarity: Double

    public var id: String { "\(accession)/\(pdb)_\(chain)" }
}

public enum HomologIndexError: Error, Sendable {
    case unavailable(String)
    case malformed(String)
    case dimensionMismatch(expected: Int, got: Int)
}

/// The bundled embedding index over one representative PDB chain per UniProt
/// accession.
public struct HomologIndex: Sendable {

    /// Vectors are L2-normalised then scaled to int8, so a dot product of two
    /// rows is `127 * 127 * cosine` and a dot product of a normalised float
    /// query with one row is `127 * cosine`.
    private static let quantisationScale: Float = 127

    /// Rows converted to float per pass. 4,096 rows of 480 floats is 7.9 MB of
    /// scratch, which stays inside the caches that make the multiply fast; the
    /// whole index as floats would be 139 MB and would defeat the point of
    /// storing it quantised.
    private static let chunkRows = 4096

    private let vectorData: Data
    private let metaData: Data

    public let count: Int
    public let dimension: Int
    private let vectorOffset: Int
    private let metaTextOffset: Int
    /// The mean subtracted from every index vector before quantisation.
    ///
    /// Internal rather than private so a test can reconstruct a pre-whitening
    /// query from a stored row: adding the mean back inverts the transform,
    /// because the stored row is already orthogonal to the removed components
    /// and projecting it again is a no-op.
    let mean: [Float]
    /// The principal directions removed after centring, row major.
    private let components: [[Float]]

    /// The similarity an unrelated pair reaches 0.1% of the time, measured over
    /// 200,000 random pairs when the index was built.
    ///
    /// This is the default floor, and it is a measurement because it cannot be
    /// guessed: before whitening it was 0.980, so any round number chosen by eye
    /// would have admitted the entire index.
    public let unrelatedSimilarityCeiling: Double

    public init(vectors: URL, metadata: URL) throws {
        do {
            vectorData = try Data(contentsOf: vectors, options: .mappedIfSafe)
            metaData = try Data(contentsOf: metadata, options: .mappedIfSafe)
        } catch {
            throw HomologIndexError.unavailable(error.localizedDescription)
        }

        guard vectorData.count >= 24, vectorData.prefix(8).elementsEqual("BOFHVEC2".utf8) else {
            throw HomologIndexError.malformed("vector file is not BOFHVEC2")
        }
        guard metaData.count >= 16, metaData.prefix(8).elementsEqual("BOFHMET1".utf8) else {
            throw HomologIndexError.malformed("metadata file is not BOFHMET1")
        }

        let vectorCount = Int(vectorData.readUInt32(at: 8))
        // Local first: reading `self.dimension` inside the closures below would
        // be capturing a stored property before initialisation is complete.
        let width = Int(vectorData.readUInt32(at: 12))
        dimension = width
        let encoding = vectorData.readUInt32(at: 16)
        guard encoding == 1 else {
            throw HomologIndexError.malformed("unsupported vector encoding \(encoding)")
        }
        let componentCount = Int(vectorData.readUInt32(at: 20))
        unrelatedSimilarityCeiling = Double(vectorData.readFloat32(at: 24))

        // A local copy of the mapped data. Referring to the stored property
        // inside these closures makes them capture `self`, which is not yet
        // initialised; `Data` is copy-on-write so this costs nothing.
        let bytes = vectorData
        var cursor = 28
        let meanBase = cursor
        mean = (0..<width).map { bytes.readFloat32(at: meanBase + $0 * 4) }
        cursor += width * 4
        let componentBase = cursor
        components = (0..<componentCount).map { row in
            let base = componentBase + row * width * 4
            return (0..<width).map { bytes.readFloat32(at: base + $0 * 4) }
        }
        cursor += componentCount * width * 4
        vectorOffset = cursor

        let metaCount = Int(metaData.readUInt32(at: 8))
        metaTextOffset = Int(metaData.readUInt32(at: 12))

        // A vector file and a metadata file from different builds would line up
        // structurally and return the right similarity attached to the wrong
        // protein, which is worse than failing to load.
        guard vectorCount == metaCount else {
            throw HomologIndexError.malformed(
                "\(vectorCount) vectors against \(metaCount) metadata records: "
                    + "these two files are from different builds")
        }
        guard vectorOffset + vectorCount * width <= vectorData.count else {
            throw HomologIndexError.malformed("vector file is shorter than its header claims")
        }
        count = vectorCount
    }

    /// The nearest entries to a pooled embedding, most similar first.
    ///
    /// - Parameters:
    ///   - query: a pooled embedding of the same width as the index.
    ///   - limit: how many hits to return.
    ///   - minimumSimilarity: hits below this are not returned at all. Defaults
    ///     to ``unrelatedSimilarityCeiling``, the measured 99.9th percentile of
    ///     unrelated pairs. Zero would return the nearest twenty entries for any
    ///     input including a random one, and a ranked list is read as a set of
    ///     answers whether or not it deserves to be.
    /// - Returns: hits in descending similarity, possibly fewer than `limit`.
    /// - Throws: ``HomologIndexError/dimensionMismatch(expected:got:)`` when the
    ///   query width does not match the index.
    public func search(
        _ query: [Float],
        limit: Int = 20,
        minimumSimilarity: Double? = nil
    ) throws -> [HomologHit] {
        let floorValue = minimumSimilarity ?? unrelatedSimilarityCeiling
        guard query.count == dimension else {
            throw HomologIndexError.dimensionMismatch(expected: dimension, got: query.count)
        }
        guard count > 0, limit > 0 else { return [] }

        // The same whitening the index went through. Without it the query lives
        // in a different space from the vectors it is being compared with, which
        // produces a ranking that is wrong and a similarity that still looks
        // like a plausible number.
        let whitened = whiten(query)
        var normalised = whitened
        var norm: Float = 0
        vDSP_svesq(whitened, 1, &norm, vDSP_Length(whitened.count))
        guard norm > 0 else { return [] }
        var inverse = 1 / norm.squareRoot()
        vDSP_vsmul(whitened, 1, &inverse, &normalised, 1, vDSP_Length(whitened.count))

        var scores = [Float](repeating: 0, count: count)
        let width = dimension
        let rowsPerChunk = Self.chunkRows

        // Every pointer is bound inside the closure that owns it and never
        // escapes. `array.withUnsafeBufferPointer(\.baseAddress)` is the tidy
        // way to write this and is undefined behaviour: it hands back a pointer
        // whose validity ended when the closure returned. It happens to work,
        // which is the problem.
        scores.withUnsafeMutableBufferPointer { outBuffer in
            guard let out = outBuffer.baseAddress else { return }
            normalised.withUnsafeBufferPointer { queryBuffer in
                guard let query = queryBuffer.baseAddress else { return }
                vectorData.withUnsafeBytes { raw in
                    guard let rawBase = raw.baseAddress else { return }
                    let base = rawBase.advanced(by: vectorOffset)
                        .assumingMemoryBound(to: Int8.self)
                    var floats = [Float](repeating: 0, count: rowsPerChunk * width)
                    floats.withUnsafeMutableBufferPointer { chunkBuffer in
                        guard let chunk = chunkBuffer.baseAddress else { return }
                        var row = 0
                        while row < count {
                            let rows = min(rowsPerChunk, count - row)
                            vDSP_vflt8(
                                base.advanced(by: row * width), 1, chunk, 1,
                                vDSP_Length(rows * width))
                            cblas_sgemv(
                                CblasRowMajor, CblasNoTrans,
                                Int32(rows), Int32(width), 1,
                                chunk, Int32(width),
                                query, 1, 0,
                                out.advanced(by: row), 1)
                            row += rows
                        }
                    }
                }
            }
        }

        let floor = Float(floorValue) * Self.quantisationScale
        var best: [(index: Int, score: Float)] = []
        best.reserveCapacity(limit + 1)
        for index in 0..<count where scores[index] >= floor {
            if best.count == limit, let last = best.last, scores[index] <= last.score { continue }
            let entry = (index, scores[index])
            let position = best.firstIndex { $0.score < entry.1 } ?? best.count
            best.insert(entry, at: position)
            if best.count > limit { best.removeLast() }
        }

        return best.compactMap { candidate in
            metadata(
                at: candidate.index,
                similarity: Double(candidate.score / Self.quantisationScale))
        }
    }

    /// Centre a query and project out the stored principal directions.
    func whiten(_ query: [Float]) -> [Float] {
        var centred = query
        if mean.count == query.count {
            for index in centred.indices { centred[index] -= mean[index] }
        }
        for component in components where component.count == centred.count {
            var projection: Float = 0
            vDSP_dotpr(centred, 1, component, 1, &projection, vDSP_Length(centred.count))
            var scale = -projection
            vDSP_vsma(component, 1, &scale, centred, 1, &centred, 1, vDSP_Length(centred.count))
        }
        return centred
    }

    /// Decode one metadata record. Records are read on demand, so a search
    /// touches a handful of pages rather than the whole 8 MB table.
    private func metadata(at index: Int, similarity: Double) -> HomologHit? {
        guard index >= 0, index < count else { return nil }
        let tableOffset = 16 + index * 4
        let start = metaTextOffset + Int(metaData.readUInt32(at: tableOffset))
        let end = metaTextOffset + Int(metaData.readUInt32(at: tableOffset + 4))
        guard start <= end, end <= metaData.count else { return nil }

        let line = String(decoding: metaData[start..<end], as: UTF8.self)
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 9 else { return nil }

        return HomologHit(
            accession: String(fields[0]),
            pdb: String(fields[1]),
            chain: String(fields[2]),
            resolution: Double(fields[3]),
            method: String(fields[4]),
            residueCount: Int(fields[5]) ?? 0,
            structureCount: Int(fields[6]) ?? 0,
            title: String(fields[7]),
            sequence: String(fields[8]),
            similarity: similarity)
    }
}

extension Data {
    /// Little-endian `UInt32` at a byte offset, without assuming alignment.
    ///
    /// The obvious `load(fromByteOffset:as:)` traps on an unaligned address on
    /// some architectures, and these offsets are computed from file contents
    /// rather than guaranteed by a layout.
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }

    func readInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset))
    }

    /// Little-endian `Float32` at a byte offset, without assuming alignment.
    func readFloat32(at offset: Int) -> Float {
        Float(bitPattern: readUInt32(at: offset))
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }
}
