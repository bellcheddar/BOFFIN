//  AudioGraphTests.swift
//  BoffinChartsTests
//
//  A chart nobody can hear is a chart half the point of which is missing, and a
//  summary that says what the extremes ARE without saying where they are is a
//  number rather than a place to look.

import Accessibility
import Testing

@testable import BoffinCharts

@Suite("Audio graph")
struct AudioGraphTests {

    private let descriptor = TrackChartDescriptor(
        title: "Hydropathy", values: [nil, -1.0, 2.5, -3.2, 0.4, nil])

    /// "Minimum -3.2" is a number. "Lowest at residue 4" is somewhere to go.
    @Test("The summary says where the extremes are, not only what they are")
    func summaryNamesPositions() {
        let pairs: [(x: Double, y: Double)] = [(2, -1.0), (3, 2.5), (4, -3.2), (5, 0.4)]
        let text = descriptor.summary(pairs, lowest: -3.2, highest: 2.5)
        #expect(text.contains("4 residues"))
        #expect(text.contains("at residue 4"))
        #expect(text.contains("at residue 3"))
        #expect(text.contains("-3.20"))
    }

    @Test("Residue numbers are one-based, matching the ruler beside it")
    func oneBased() {
        let chart = descriptor.makeChartDescriptor()
        #expect(chart.xAxis.title == "Residue")
        let points = chart.series.first?.dataPoints ?? []
        // Index 1 in the array is residue 2. `xValue` is a wrapper rather than
        // a Double, so the assertion goes through its description: what is being
        // pinned is the numbering, not the type.
        let first = points.first.map { String(describing: $0.xValue) } ?? ""
        #expect(first.contains("2"), "first point was \(first)")
        #expect(points.count == 4)
    }

    /// Gaps in a track are gaps. Hydropathy leaves the termini blank rather than
    /// averaging a truncated window, and sonifying a zero there would be a tone
    /// where there is no measurement.
    @Test("Absent values are omitted rather than sonified as zero")
    func gapsAreOmitted() {
        let chart = descriptor.makeChartDescriptor()
        #expect(chart.series.first?.dataPoints.count == 4)
    }

    /// A zero-width range makes the tone constant rather than absent, which
    /// sounds like silence and reads as a broken graph.
    @Test("A flat track still has a range")
    func flatTrack() {
        let flat = TrackChartDescriptor(title: "Flat", values: [1.0, 1.0, 1.0])
        let chart = flat.makeChartDescriptor()
        guard let axis = chart.yAxis as? AXNumericDataAxisDescriptor else {
            Issue.record("expected a numeric axis")
            return
        }
        #expect(axis.range.upperBound > axis.range.lowerBound)
    }

    @Test("An empty track says so rather than describing nothing")
    func emptyTrack() {
        let empty = TrackChartDescriptor(title: "Empty", values: [])
        #expect(empty.summary([], lowest: 0, highest: 0) == "No values.")
        #expect(empty.makeChartDescriptor().series.first?.dataPoints.isEmpty == true)
    }
}
