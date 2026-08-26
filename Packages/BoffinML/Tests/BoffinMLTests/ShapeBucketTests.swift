//  ShapeBucketTests.swift
//  BoffinMLTests

import Foundation
import Testing

@testable import BoffinML

/// The bucket list as the conversion pipeline declares it.
///
/// Read from `convert_backbone.py` rather than copied here. The test this
/// replaces said the two "must stay in lockstep" and then compared the enum
/// against a third hardcoded copy of the same numbers, so it would have passed
/// unchanged had the converter's list been edited -- which is the one event it
/// was written to catch.
private func convertedBuckets() throws -> [Int] {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Tools/coreml/convert_backbone.py")
    let source = try String(contentsOf: script, encoding: .utf8)
    guard
        let line = source.split(separator: "\n")
            .first(where: { $0.hasPrefix("BUCKETS") }),
        let open = line.firstIndex(of: "["),
        let close = line.lastIndex(of: "]")
    else {
        throw ShapeBucketTestError.noBucketsDeclaration
    }
    return line[line.index(after: open)..<close]
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
}

private enum ShapeBucketTestError: Error {
    /// The converter no longer declares BUCKETS the way this test reads it.
    /// Failing is right: silently finding nothing would restore the tautology.
    case noBucketsDeclaration
}

@Suite("Shape bucketing")
struct ShapeBucketTests {

    @Test("Buckets are the ones the conversion pipeline declares, in order")
    func bucketsMatchConversionPipeline() throws {
        // A bucket that exists here but not in the converted model fails at
        // prediction time, on device, which is the worst place to find out.
        let declared = try convertedBuckets()
        #expect(declared.count == 6, "read \(declared) from convert_backbone.py")
        #expect(ShapeBucket.allCases.map(\.rawValue) == declared)
    }

    @Test("A sequence is padded up to the smallest fitting bucket")
    func picksSmallestFittingBucket() {
        #expect(ShapeBucket.smallestFitting(tokenCount: 1) == .tokens128)
        #expect(ShapeBucket.smallestFitting(tokenCount: 128) == .tokens128)
        #expect(ShapeBucket.smallestFitting(tokenCount: 129) == .tokens256)
        #expect(ShapeBucket.smallestFitting(tokenCount: 300) == .tokens384)
        #expect(ShapeBucket.smallestFitting(tokenCount: 1024) == .tokens1024)
    }

    @Test("A sequence longer than the largest bucket must be tiled")
    func longSequenceRequiresTiling() {
        #expect(ShapeBucket.smallestFitting(tokenCount: 1025) == nil)
    }
}
