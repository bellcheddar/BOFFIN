//  MultiArrayStrideTests.swift
//  BoffinMLTests
//
//  `MLMultiArray` is not densely packed, and the whole app has one bug class
//  that comes from forgetting it. In Phase 4 a masked-marginal scan indexed
//  logits by `token * vocabulary` instead of by the array's strides and
//  produced a completely convincing delta-LLR heatmap of garbage: index 0 reads
//  correctly because its offset is zero, and everything after it is quietly
//  shifted.
//
//  These tests do not assert that the strides are padded, because whether they
//  are is Core ML's business and can change between OS releases. They assert
//  that the code READS THEM, by constructing arrays in the shapes the heads use
//  and checking the reported strides describe the buffer the code writes into.

import CoreML
import Testing

@testable import BoffinML

@Suite("MLMultiArray strides")
struct MultiArrayStrideTests {

    /// The head input layout: (1, width, 1, window).
    @Test("A head-shaped array reports strides that cover its own elements")
    func headInputStrides() throws {
        let width = 480
        let window = AnalysisHeads.headWindow
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: width), 1, NSNumber(value: window)],
            dataType: .float16)

        let strides = array.strides.map(\.intValue)
        #expect(strides.count == 4)

        // The last axis may or may not be contiguous, and the channel stride may
        // or may not equal the window. What must hold is that indexing by the
        // reported strides stays inside the allocation, which is the property
        // the head runner relies on.
        let highest =
            (width - 1) * strides[1] + (window - 1) * strides[3]
        #expect(highest < array.count)
    }

    /// Writing by stride and reading back by stride must round-trip exactly.
    /// This is the property the head runner needs and the one that silently
    /// fails when an offset is computed by hand.
    @Test("Writing by stride round-trips every position and channel")
    func strideRoundTrip() throws {
        let width = 8
        let window = 16
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: width), 1, NSNumber(value: window)],
            dataType: .float16)

        array.withUnsafeMutableBytes { raw, strides in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float16.self) else {
                return
            }
            let channelStride = strides.count > 1 ? strides[1] : window
            let positionStride = strides.count > 3 ? strides[3] : 1
            for channel in 0..<width {
                for position in 0..<window {
                    base[channel * channelStride + position * positionStride] =
                        Float16(channel * 100 + position)
                }
            }
        }

        // Read back through MLMultiArray's own subscript, which is stride
        // correct by construction. If the write used the wrong offsets, this
        // disagrees.
        for channel in 0..<width {
            for position in 0..<window {
                let value = array[
                    [0, NSNumber(value: channel), 0, NSNumber(value: position)]
                ].doubleValue
                #expect(
                    value == Double(channel * 100 + position),
                    "channel \(channel) position \(position) read back as \(value)")
            }
        }
    }

    /// The head runner falls back to hand-computed offsets when an array
    /// reports fewer strides than axes. That fallback should never fire for the
    /// shapes the heads use, and a test is cheaper than finding out at runtime
    /// that it did.
    @Test("A head-shaped array always reports one stride per axis")
    func stridesCoverEveryAxis() throws {
        for window in [128, AnalysisHeads.headWindow] {
            let array = try MLMultiArray(
                shape: [1, 480, 1, NSNumber(value: window)], dataType: .float16)
            #expect(array.strides.count == array.shape.count)
            #expect(array.strides.allSatisfy { $0.intValue > 0 })
        }
    }
}
