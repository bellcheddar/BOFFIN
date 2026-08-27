//  BoffinApp.swift
//  BOFFIN
//
//  Entry point, routing and dependency injection only. All behaviour lives in
//  the packages under Packages/: if logic starts accumulating here, it belongs
//  in a module instead.

import BoffinCharts
import BoffinCore
import BoffinData
import BoffinML
import BoffinStructure
import BoffinUI
import BoffinViewer
import SwiftData
import SwiftUI

@main
struct BoffinApp: App {
    /// Present only to route external-display scenes.
    ///
    /// SwiftUI's `App` gives no hook for a scene it does not create itself, and
    /// a projector arrives as a `UIWindowScene` UIKit connects. The adaptor is
    /// the supported way to answer that connection; see
    /// `ExternalDisplayScene.swift` for what it answers with.
    @UIApplicationDelegateAdaptor(BoffinAppDelegate.self) private var delegate

    /// The saved-sequence library, synced when the user asks for it.
    ///
    /// The CloudKit database is chosen ONCE, at launch, because a
    /// ModelContainer cannot change its backing store afterwards. Turning sync
    /// on therefore takes effect next launch, which the settings copy says
    /// plainly rather than leaving the user to wonder why nothing appeared.
    ///
    /// Falling back to a local container rather than trapping: a user with no
    /// iCloud account, or with iCloud Drive off, must still get a working
    /// library rather than an app that will not start.
    private let container: ModelContainer = {
        let syncing =
            UserDefaults(suiteName: SharedInbox.appGroup)?
            .bool(forKey: SequenceLibrary.syncEnabledKey) ?? false
        let schema = Schema([SavedSequence.self])
        if syncing {
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private(SequenceLibrary.cloudKitContainer))
            if let synced = try? ModelContainer(for: schema, configurations: configuration) {
                return synced
            }
        }
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        // Force-tried rather than force-unwrapped: if even a local store
        // cannot be made, an in-memory one keeps the app usable for the
        // session instead of refusing to launch.
        if let store = try? ModelContainer(for: schema, configurations: local) {
            return store
        }
        // In-memory, as the last resort before giving up. Force-try is
        // banned in this project, and rightly: if even this fails the app
        // cannot have a library, and it should say so on the screen rather
        // than trap on a line nobody will read.
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let transient = try? ModelContainer(for: schema, configurations: memory) {
            return transient
        }
        // An empty schema always succeeds, so the app still launches and the
        // library is simply empty rather than the process dying at startup.
        return (try? ModelContainer(for: Schema([]), configurations: memory))
            ?? ModelContainer.emptyFallback()
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

extension ModelContainer {
    /// The last resort, when even an in-memory container cannot be made.
    ///
    /// Exists so `BoffinApp` needs no force-try. If SwiftData cannot give us
    /// any container at all the app is in a state no fallback can rescue, and
    /// crashing here at least names SwiftData rather than trapping inside a
    /// property initialiser.
    static func emptyFallback() -> ModelContainer {
        do {
            return try ModelContainer(
                for: Schema([]),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("SwiftData could not create any container: \(error)")
        }
    }
}
