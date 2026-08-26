//  ShareViewController.swift
//  BOFFINShare
//
//  Takes a protein sequence shared from another app and hands it to BOFFIN.
//
//  The extension deliberately does NO analysis. The models are 138 MB and an
//  app extension gets a fraction of the memory an app does, so loading them
//  here would be killed by the system and would duplicate the bundle besides.
//  Its whole job is to get the text across the boundary and open the app.
//
//  The text travels through an App Group container rather than the URL. A URL
//  can carry a 300-residue sequence comfortably and cannot carry a multi-record
//  FASTA file, and the failure would be silent truncation of a sequence rather
//  than an error -- the app would analyse the first N residues and report on
//  them as though they were the protein.

import BoffinCore
import Social
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handle() }
    }

    private func handle() async {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
            let providers = item.attachments
        else { return finish(nil) }

        for provider in providers {
            if let text = await provider.loadText() {
                return finish(text)
            }
        }
        finish(nil)
    }

    /// Store the text and open the app, or just close if there was nothing.
    private func finish(_ text: String?) {
        if let text, !text.isEmpty {
            SharedInbox.write(text)
            // `extensionContext.open` rather than UIApplication.shared.open,
            // which an extension is not allowed to call.
            extensionContext?.open(SharedInbox.openURL)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

extension NSItemProvider {

    /// The shared text, whether it arrived as text or as a file.
    ///
    /// Both are tried because "share a FASTA" means a file from Files and a
    /// selection from Mail, and an extension that handles only one of them
    /// looks broken in the other place.
    func loadText() async -> String? {
        for type in [UTType.plainText, UTType.text, UTType.utf8PlainText] {
            guard hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            if let loaded = try? await loadItem(forTypeIdentifier: type.identifier) {
                if let string = loaded as? String { return string }
                if let data = loaded as? Data { return String(data: data, encoding: .utf8) }
                if let url = loaded as? URL { return try? String(contentsOf: url, encoding: .utf8) }
            }
        }
        if hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            let loaded = try? await loadItem(forTypeIdentifier: UTType.fileURL.identifier),
            let url = loaded as? URL
        {
            // Security-scoped: a file handed over by another app is not
            // readable without asking for access first, and the read simply
            // returns nil rather than failing loudly.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }
}
