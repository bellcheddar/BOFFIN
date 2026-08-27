//  SavedSequence.swift
//  BoffinCore
//
//  A sequence the user chose to keep.
//
//  Until this existed the app held exactly one sequence, in memory, and lost
//  it on quit. That is why CloudKit had nothing to sync: there was no store,
//  only a value.
//
//  Every rule CloudKit imposes on a SwiftData model is obeyed here, and each
//  one fails at RUN time rather than compile time if it is not:
//
//  * Every attribute has a default. CloudKit cannot represent a required
//    field, because a record created on another device by an older build
//    would have nothing to put in it.
//  * No `@Attribute(.unique)`. Uniqueness cannot be enforced across devices
//    that have not synced yet, and the container refuses to load at all.
//  * No non-optional relationships, for the same reason.
//
//  Breaking any of them gives "NSPersistentStoreCoordinator has no persistent
//  stores" on launch, which names nothing useful.

import Foundation
import SwiftData

@Model
public final class SavedSequence {

    public var name: String = ""
    public var letters: String = ""
    public var savedAt: Date = Date.distantPast
    /// The user's own note. Not analysis output: results are recomputed, and
    /// syncing a stale conclusion would be worse than recomputing it.
    public var note: String = ""

    public init(name: String, letters: String, savedAt: Date = Date(), note: String = "") {
        self.name = name
        self.letters = letters
        self.savedAt = savedAt
        self.note = note
    }

    public var residueCount: Int { letters.count }

    /// A short preview for a list row.
    public var preview: String {
        letters.count <= 24 ? letters : String(letters.prefix(24)) + "…"
    }
}

public enum SequenceLibrary {

    /// The CloudKit container backing the library.
    ///
    /// Must match the `com.apple.developer.icloud-container-identifiers`
    /// entitlement exactly. A mismatch is not a build error: the container
    /// fails to load at launch and every saved sequence silently disappears.
    public static let cloudKitContainer = "iCloud.com.mdeller.boffin"

    /// Whether the user has turned sync on.
    ///
    /// Default OFF, deliberately. The app's stated position is that nothing
    /// leaves the device, and that has to remain true for anyone who does not
    /// choose otherwise. Stored in the shared container so extensions see the
    /// same answer.
    public static let syncEnabledKey = "boffin.library.syncEnabled"
}
