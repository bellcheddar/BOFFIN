//  AudioGraph.swift
//  BoffinCharts
//
//  Audio Graphs for continuous tracks, so a VoiceOver user can HEAR hydropathy,
//  charge or a delta-LLR profile rather than being read a summary of it.
//
//  The build plan calls this out as not optional polish, and it is right: a
//  track is a shape, and the question a shape answers is "where does it change".
//  A sentence saying "mean -0.4, minimum -3.2 at residue 41" is a different and
//  much smaller answer than a tone that falls away under your finger.
//
//  `AXChartDescriptor` is the system API for this. It costs one conformance and
//  it is the difference between a chart being described and a chart being
//  usable.

import Accessibility
import BoffinCore
import SwiftUI

/// An Audio Graph over one continuous residue track.
public struct TrackChartDescriptor: AXChartDescriptorRepresentable {
    private let title: String
    private let values: [Double?]

    public init(title: String, values: [Double?]) {
        self.title = title
        self.values = values
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        // Residues are one-based on every axis in this app, because that is how
        // a paper numbers them, and an axis that disagrees with the ruler beside
        // it is worse than no axis.
        // Kept as plain pairs alongside the descriptor's points. `AXDataPoint`
        // stores its y as an optional wrapper, so reducing over it needs
        // unwrapping at every step; the arithmetic is clearer on the numbers
        // that produced it.
        let pairs = values.enumerated().compactMap { index, value -> (x: Double, y: Double)? in
            guard let value else { return nil }
            return (Double(index + 1), value)
        }
        let points = pairs.map { AXDataPoint(x: $0.x, y: $0.y) }
        let lowest = pairs.map(\.y).min() ?? 0
        let highest = pairs.map(\.y).max() ?? 1

        let xAxis = AXNumericDataAxisDescriptor(
            title: "Residue",
            range: 1...Double(max(values.count, 1)),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                "residue \(Int(value.rounded()))"
            })

        let yAxis = AXNumericDataAxisDescriptor(
            title: title,
            // A flat track has no range, and a zero-width range makes the tone
            // constant rather than absent, which sounds like silence and reads
            // as a broken graph.
            range: lowest...(highest > lowest ? highest : lowest + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                String(format: "%.2f", value)
            })

        let series = AXDataSeriesDescriptor(
            name: title, isContinuous: true, dataPoints: points)

        return AXChartDescriptor(
            title: title,
            summary: summary(pairs, lowest: lowest, highest: highest),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series])
    }

    public func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        // Rebuilt rather than mutated: the descriptor is cheap and a partial
        // update is how an axis comes to describe data it no longer holds.
    }

    /// The spoken summary, which is what a user hears before the tones.
    ///
    /// Where the extremes ARE, not just what they are. "Minimum -3.2" is a
    /// number; "lowest at residue 41" is a place to go and look.
    func summary(
        _ pairs: [(x: Double, y: Double)], lowest: Double, highest: Double
    ) -> String {
        guard !pairs.isEmpty else { return "No values." }
        let lowestAt = pairs.min { $0.y < $1.y }?.x ?? 0
        let highestAt = pairs.max { $0.y < $1.y }?.x ?? 0
        return String(
            format:
                "%d residues. Lowest %.2f at residue %d, highest %.2f at residue %d.",
            pairs.count, lowest, Int(lowestAt), highest, Int(highestAt))
    }
}

extension View {
    /// Attach an Audio Graph to a continuous track.
    ///
    /// A no-op for a track that is not continuous, because a categorical track
    /// has no curve to sonify and a tone sequence over arbitrary category
    /// indices would be noise presented as information.
    public func audioGraph(for track: AnyResidueTrack) -> some View {
        Group {
            if case .continuous(let values) = track.values {
                self.accessibilityChartDescriptor(
                    TrackChartDescriptor(title: track.title, values: values))
            } else {
                self
            }
        }
    }
}
