//  OpenSetModel.swift
//  BoffinML
//
//  Telling the family classifier when it is looking at something it has never
//  seen.
//
//  The classifier is closed set: it knows 100 families and must answer with one
//  of them, so a protein from outside that set is assigned the nearest family,
//  confidently. Confidence cannot reliably catch it, because the model genuinely
//  is confident.
//
//  What can, measured rather than assumed. `Tools/heads/openset_experiment.py`
//  holds out whole FAMILIES (twenty of the hundred, five splits) and compares
//  five scores on about 1,500 genuinely unseen sequences:
//
//      Mahalanobis distance    0.969 +/- 0.005     <- this
//      max softmax             0.945 +/- 0.014
//      max logit               0.896 +/- 0.024
//      energy                  0.893 +/- 0.025
//      centroid cosine         0.850 +/- 0.016     <- what this replaces
//
//  Mahalanobis is not only the best but by far the most STABLE across splits,
//  which matters more than the mean: a score whose usefulness depends on which
//  families happen to be missing is not one to ship a threshold on.
//
//  Holding out whole families is the load-bearing choice. A sequence-level
//  split leaves each held-out sequence's family in the training set, so the
//  model has seen its fold, its motifs and its neighbours, and "unknown" would
//  mean nothing.
//
//  **This is not a solution and must not be presented as one.** At the shipped
//  threshold it catches about four unseen proteins in five, so one in five still
//  receives a confident wrong family. The on-screen statement that the
//  classifier is closed set stays exactly as it was.

import Accelerate
import Foundation

/// Mahalanobis distance to the nearest training family.
///
/// Stored pre-whitened: with a shared covariance, Mahalanobis distance is an
/// ordinary squared Euclidean distance after multiplying by the matrix square
/// root of the precision. That turns a 480x480 quadratic form per class into
/// two matrix products, which is what makes this affordable per classification
/// rather than something to think twice about.
struct OpenSetModel: Sendable {
    /// Squared distance above which a protein is called out of distribution.
    let threshold: Double

    private let width: Int
    private let classCount: Int
    /// Row-major `width x width`.
    private let whitener: [Float]
    /// Class means already multiplied by the whitener, `classCount x width`.
    private let whitenedMeans: [Float]
    /// The squared norm of each whitened mean, precomputed for the expansion.
    private let meanNorms: [Float]

    /// Load from the binary the trainer writes.
    ///
    /// Binary rather than JSON because the whitener is 480x480 and would be
    /// 230,400 numbers of decimal text. Float32 rather than float16 because the
    /// precision matrix has a wide dynamic range and feeds a SQUARED distance,
    /// where a relative error is squared with it.
    ///
    /// - Returns: `nil` for any problem at all. The asset is optional: the app
    ///   falls back to the weaker cosine rather than failing to classify.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let magic = "BOFOSET1"
        let headerSize = magic.utf8.count + 8 + 4
        guard data.count > headerSize,
            data.prefix(magic.utf8.count) == Data(magic.utf8)
        else { return nil }

        var offset = magic.utf8.count
        func readInt32() -> Int {
            defer { offset += 4 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            }
            return Int(value)
        }
        let classes = readInt32()
        let dimension = readInt32()
        let thresholdValue = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: Float32.self)
        }
        offset += 4

        guard classes > 0, dimension > 0, classes < 100_000, dimension < 100_000 else {
            return nil
        }
        let whitenerCount = dimension * dimension
        let meansCount = classes * dimension
        // Assert the whole payload is present before reading any of it. A
        // truncated download once left this project with 7% of the PDB and no
        // error at all, which redefined a result rather than failing.
        guard data.count >= offset + (whitenerCount + meansCount) * 4 else { return nil }

        func readFloats(_ count: Int) -> [Float] {
            let start = data.startIndex + offset
            let bytes = data.subdata(in: start..<(start + count * 4))
            offset += count * 4
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let matrix = readFloats(whitenerCount)
        let means = readFloats(meansCount)

        // Pre-multiply the means once at load, not per classification.
        var whitened = [Float](repeating: 0, count: meansCount)
        vDSP_mmul(
            means, 1, matrix, 1, &whitened, 1,
            vDSP_Length(classes), vDSP_Length(dimension), vDSP_Length(dimension))

        var norms = [Float](repeating: 0, count: classes)
        whitened.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<classes {
                var sum: Float = 0
                vDSP_svesq(base + index * dimension, 1, &sum, vDSP_Length(dimension))
                norms[index] = sum
            }
        }

        self.threshold = Double(thresholdValue)
        self.width = dimension
        self.classCount = classes
        self.whitener = matrix
        self.whitenedMeans = whitened
        self.meanNorms = norms
    }

    /// Squared Mahalanobis distance to the nearest family.
    ///
    /// - Returns: `nil` when the embedding is the wrong width, rather than a
    ///   number computed from a mismatch. A distance is compared against a
    ///   threshold, and a plausible wrong number is worse than no number.
    func distance(from embedding: [Float]) -> Double? {
        guard embedding.count == width else { return nil }

        var whitenedQuery = [Float](repeating: 0, count: width)
        vDSP_mmul(
            embedding, 1, whitener, 1, &whitenedQuery, 1,
            1, vDSP_Length(width), vDSP_Length(width))

        var querySquared: Float = 0
        vDSP_svesq(whitenedQuery, 1, &querySquared, vDSP_Length(width))

        // |q - m|^2 = |q|^2 - 2 q.m + |m|^2, with the two norms already known.
        var best = Float.greatestFiniteMagnitude
        whitenedMeans.withUnsafeBufferPointer { means in
            guard let base = means.baseAddress else { return }
            for index in 0..<classCount {
                var dot: Float = 0
                vDSP_dotpr(whitenedQuery, 1, base + index * width, 1, &dot, vDSP_Length(width))
                let squared = querySquared - 2 * dot + meanNorms[index]
                if squared < best { best = squared }
            }
        }
        guard best < .greatestFiniteMagnitude else { return nil }
        // Clamp at zero: the expansion is exact in real arithmetic and can go a
        // hair negative in floating point when a query sits on a class mean,
        // and a negative squared distance reaching a comparison reads as
        // maximally in-distribution when it means the opposite.
        return Double(max(best, 0))
    }
}
