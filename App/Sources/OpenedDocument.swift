//  OpenedDocument.swift
//  BOFFIN
//
//  Phase 10: a FASTA file shared from Mail, Files or a colleague opens here.
//
//  Two halves, and the plist one is the half that is invisible when it is
//  missing. Without `CFBundleDocumentTypes` the share sheet never offers BOFFIN
//  and `onOpenURL` is never called, which looks exactly like a bug in the
//  handler. Without the handler the file opens the app and nothing happens.
//
//  Security-scoped access is not optional either. A file that arrives from
//  another app's container is readable only between `startAccessingSecurityScopedResource`
//  and its stop, and skipping that reads the file successfully in the simulator
//  and returns nothing on a device.

import BoffinCore
import Foundation

enum OpenedDocument {

    /// What went wrong, in the user's terms rather than the file system's.
    enum Failure: Error, Equatable {
        case unreadable(String)
        case tooLarge(bytes: Int)
        case notText

        var message: String {
            switch self {
            case .unreadable(let reason):
                "That file could not be read: \(reason)"
            case .tooLarge(let bytes):
                "That file is \(bytes / 1_000_000) MB. BOFFIN reads sequence files, "
                    + "and one that large is almost certainly something else."
            case .notText:
                "That file is not text, so there is no sequence in it to read."
            }
        }
    }

    /// A sequence file large enough to be a mistake.
    ///
    /// The largest protein anybody works with is a few hundred kilobytes of
    /// FASTA. Twenty megabytes is a genome, and reading one into a string on a
    /// phone is how an app is killed by the system rather than by an error.
    static let maximumBytes = 20 * 1_000_000

    /// Read a dropped or shared file.
    ///
    /// - Parameter url: the file, possibly in another app's container.
    /// - Returns: its text.
    /// - Throws: ``Failure`` with a message meant for a person.
    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size =
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else { throw Failure.tooLarge(bytes: size) }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }

        // Decoded permissively rather than strictly. A FASTA file written on a
        // Windows machine in 1998 is not valid UTF-8 and is still a sequence
        // file; refusing it would be correct and useless. Anything genuinely
        // binary is caught below instead.
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { throw Failure.notText }

        // A NUL byte in the first kilobyte means binary. FASTA never contains
        // one, and this catches a .bcif or an image dropped on the app before
        // the parser produces a confusing diagnostic about residues.
        if data.prefix(1024).contains(0) { throw Failure.notText }
        return text
    }
}
