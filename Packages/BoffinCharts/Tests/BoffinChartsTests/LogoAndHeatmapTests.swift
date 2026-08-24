//  LogoAndHeatmapTests.swift
//  BoffinChartsTests

import BoffinCore
import Foundation
import Testing

@testable import BoffinCharts

private func matrix(_ columns: [[Double]]) -> LLRMatrix {
    LLRMatrix(
        positions: Array(columns.indices),
        wildType: Array(repeating: AminoAcid.methionine, count: columns.count),
        values: columns)
}

@Suite("Sequence logo mathematics in context")
struct LogoContextTests {

    @Test("A flat column carries no information")
    func flatColumnIsZeroBits() {
        // All twenty equally likely: entropy is maximal, information zero, so
        // the logo column should have no height at all.
        let flat = [Double](repeating: 0, count: 20)
        let probabilities = softmax(flat)
        #expect(abs(InformationContent.bits(probabilities)) < 1e-9)
    }

    @Test("A dominated column carries nearly the maximum")
    func dominatedColumnIsHigh() {
        var scores = [Double](repeating: -20, count: 20)
        scores[0] = 0
        let bits = InformationContent.bits(softmax(scores))
        #expect(bits > InformationContent.maximumBits - 0.01)
    }

    @Test("Softmax over delta-LLR recovers a probability distribution")
    func softmaxSumsToOne() {
        let probabilities = softmax([0, -1, -2, -3])
        #expect(abs(probabilities.reduce(0, +) - 1) < 1e-12)
        #expect(probabilities.allSatisfy { $0 >= 0 })
    }

    private func softmax(_ scores: [Double]) -> [Double] {
        let maximum = scores.max() ?? 0
        let exponentials = scores.map { Foundation.exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }
}

@Suite("Heatmap geometry")
struct HeatmapGeometryTests {

    @Test("Row height is fixed so the amino acid axis stays legible")
    func rowHeightIsFixed() {
        // Twenty rows whatever the zoom: scaling them would make the axis
        // labels unreadable before the cells became useful.
        #expect(LLRHeatmapView.rowHeight >= 12)
        #expect(LLRHeatmapView.labelWidth > 0)
    }

    @Test("Cell width bounds keep cells visible and the axis usable")
    func cellWidthBounds() {
        #expect(LLRHeatmapView.minimumCellWidth > 0)
        #expect(LLRHeatmapView.maximumCellWidth > LLRHeatmapView.minimumCellWidth)
    }
}
