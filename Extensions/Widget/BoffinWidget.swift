//  BoffinWidget.swift
//  BOFFINWidget
//
//  The last analysis, on the home screen.
//
//  A widget gets a few tens of megabytes and a few seconds, so it runs no
//  model and reads no structure. It shows numbers the app has already computed
//  and left in the shared container. Anything else would be killed by the
//  system, and intermittently rather than reliably, which is worse.

import BoffinCore
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: AnalysisSnapshot?
}

struct Provider: TimelineProvider {

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: Self.example)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        // The gallery preview gets the example rather than the user's real
        // data: a widget being chosen in the gallery should look like
        // something, and on a fresh install there is nothing to show.
        let stored = SharedInbox.readSnapshot()
        completion(Entry(date: Date(), snapshot: context.isPreview ? Self.example : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // `.never`: this changes when the app analyses something, not on a
        // clock. The app reloads the timeline itself, so polling would spend
        // the widget's refresh budget to display the same numbers.
        completion(
            Timeline(
                entries: [Entry(date: Date(), snapshot: SharedInbox.readSnapshot())],
                policy: .never))
    }

    static let example = AnalysisSnapshot(
        name: "CDK2_HUMAN", residueCount: 298, disorderedFraction: 0.11,
        helixFraction: 0.34, strandFraction: 0.19,
        familyName: "Protein kinase domain", familyConfidence: 0.98,
        analysedAt: Date())
}

struct BoffinWidgetView: View {
    var entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(s.residueCount) residues")
                    .font(.caption2).foregroundStyle(.secondary)
                if family != .systemSmall, let name = s.familyName {
                    Text(name).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                CompositionBar(snapshot: s)
                Text("\(Int(s.disorderedFraction * 100))% disordered")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            // Says what to do, rather than showing an empty frame. A blank
            // widget reads as broken; this one reads as waiting.
            VStack(alignment: .leading, spacing: 4) {
                Text("BOFFIN").font(.caption.weight(.semibold))
                Text("Analyse a sequence to see it here")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Helix, strand and the rest, as one bar.
struct CompositionBar: View {
    let snapshot: AnalysisSnapshot

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                segment(.red, snapshot.helixFraction, geometry.size.width)
                segment(.blue, snapshot.strandFraction, geometry.size.width)
                segment(
                    .gray, max(0, 1 - snapshot.helixFraction - snapshot.strandFraction),
                    geometry.size.width)
            }
        }
        .frame(height: 6)
        .clipShape(.rect(cornerRadius: 3))
    }

    private func segment(_ colour: Color, _ fraction: Double, _ total: CGFloat) -> some View {
        colour.frame(width: max(0, total * fraction))
    }
}

struct BoffinWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BoffinLastAnalysis", provider: Provider()) { entry in
            BoffinWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Last analysis")
        .description("The most recent sequence BOFFIN analysed.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BoffinWidgetBundle: WidgetBundle {
    var body: some Widget { BoffinWidget() }
}
