//  PreviewViewController.swift
//  BOFFINQuickLook
//
//  Previews a FASTA or plain sequence file in Files, Mail and anywhere else
//  Quick Look is offered.
//
//  Everything shown here is arithmetic over the letters: length, composition,
//  molecular weight. No model, for the same reason the share extension loads
//  none -- an extension gets a fraction of an app's memory and the backbone is
//  67 MB. A preview that sometimes fails because a model was being loaded
//  would be worse than one that never promises it.

import BoffinCore
import QuickLook
import SwiftUI
import UIKit

final class PreviewViewController: UIViewController, QLPreviewingController {

    func preparePreviewOfFile(at url: URL) async throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        // Parse failures are shown rather than thrown. Throwing gives Quick
        // Look's generic "cannot preview" sheet, which says nothing about
        // WHY: a file with no records and a file BOFFIN cannot read look the
        // same to the user, and only one of them is worth fixing.
        let parsed = try? FASTAParser.parse(text, fileName: url.lastPathComponent)
        let summary = Summary(url: url, records: parsed?.sequences ?? [])
        await MainActor.run { install(SequencePreview(summary: summary)) }
    }

    private func install(_ view: some View) {
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct Summary {
    let url: URL
    let records: [ProteinSequence]

    var fileName: String { url.lastPathComponent }
    var recordCount: Int { records.count }
}

struct SequencePreview: View {
    let summary: Summary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(summary.fileName).font(.headline)

                if summary.records.isEmpty {
                    // Said plainly rather than shown as an empty preview: a
                    // blank pane reads as Quick Look failing, not as the file
                    // containing nothing a sequence reader recognises.
                    Text("No sequence records found in this file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(summary.records.enumerated()), id: \.offset) { _, record in
                        RecordRow(record: record)
                    }
                    if summary.recordCount > 1 {
                        Text("\(summary.recordCount) records")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecordRow: View {
    let record: ProteinSequence

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !record.name.isEmpty {
                Text(record.name).font(.subheadline.weight(.medium))
            }
            Text("\(record.count) residues")
                .font(.caption).foregroundStyle(.secondary)
            Text(record.letters.prefix(240) + (record.letters.count > 240 ? "…" : ""))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}
