//  InformationContentTests.swift
//  BoffinChartsTests
//
//  Sequence logo mathematics, checked against hand-computed values. Written
//  first, from the published definition, because a logo that is subtly wrong
//  still looks like a logo.

import Foundation
import Testing

@testable import BoffinCharts

@Suite("Sequence logo information content")
struct InformationContentTests {

    @Test("A uniform distribution over twenty residues carries zero information")
    func uniformDistributionIsZeroBits() {
        let uniform = Array(repeating: 1.0 / 20.0, count: 20)
        // H = log2(20), so R = log2(20) - log2(20) = 0.
        #expect(abs(InformationContent.bits(uniform)) < 1e-12)
    }

    @Test("A fully conserved position carries log2(20) bits")
    func conservedPositionIsMaximumBits() {
        var distribution = Array(repeating: 0.0, count: 20)
        distribution[0] = 1.0
        // H = 0, so R = log2(20) = 4.3219...
        #expect(abs(InformationContent.bits(distribution) - log2(20.0)) < 1e-12)
    }

    @Test("An even two-way split has one bit of entropy")
    func twoWaySplitEntropy() {
        #expect(abs(InformationContent.entropy([0.5, 0.5]) - 1.0) < 1e-12)
    }

    @Test("Zero-probability residues do not produce NaN")
    func zeroProbabilitiesAreSkipped() {
        // The limit of p*log(p) as p tends to zero is zero, but the naive
        // computation is 0 * -inf = NaN, which would silently blank a column.
        let distribution = [0.5, 0.5] + Array(repeating: 0.0, count: 18)
        let bits = InformationContent.bits(distribution)
        #expect(!bits.isNaN)
        #expect(abs(bits - (log2(20.0) - 1.0)) < 1e-12)
    }
}
