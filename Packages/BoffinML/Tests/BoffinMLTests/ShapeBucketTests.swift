//  ShapeBucketTests.swift
//  BoffinMLTests

import Testing

@testable import BoffinML

@Suite("Shape bucketing")
struct ShapeBucketTests {

    @Test("Buckets are the six the conversion pipeline declares, in order")
    func bucketsMatchConversionPipeline() {
        // These must stay in lockstep with the EnumeratedShapes declared in
        // Tools/coreml/convert_backbone.py. A bucket that exists here but not
        // in the converted model fails at prediction time, on device.
        #expect(ShapeBucket.allCases.map(\.rawValue) == [128, 256, 384, 512, 768, 1024])
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
