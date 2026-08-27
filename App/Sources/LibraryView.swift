//  LibraryView.swift
//  BOFFIN
//
//  Sequences the user has kept, and the switch that syncs them.
//
//  A sheet rather than a sixth tab. Five tabs already fill the bar on a phone
//  at the larger accessibility text sizes, and a library is something reached
//  deliberately rather than one of the app's modes.

import BoffinCore
import BoffinUI
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Bindable var store: SequenceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSequence.savedAt, order: .reverse) private var saved: [SavedSequence]

    @AppStorage(SequenceLibrary.syncEnabledKey, store: .boffinShared)
    private var syncEnabled = false

    var body: some View {
        NavigationStack {
            List {
                if let sequence = store.sequence {
                    Section {
                        Button {
                            save(sequence)
                        } label: {
                            Label("Save \(sequence.name)", systemImage: "square.and.arrow.down")
                        }
                        .minimumTouchTarget()
                        .accessibilityIdentifier("boffin.library.save")
                    }
                }

                Section("Saved") {
                    if saved.isEmpty {
                        Text("Nothing saved yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(saved) { item in
                        Button {
                            store.load(text: item.letters, fileName: item.name)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.body)
                                Text("\(item.residueCount) residues · \(item.preview)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .minimumTouchTarget()
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(saved[index]) }
                    }
                }

                Section {
                    Toggle("Sync with iCloud", isOn: $syncEnabled)
                        .accessibilityIdentifier("boffin.library.sync")
                } footer: {
                    // Both halves are load-bearing. The first is the honest
                    // qualification of "everything stays on the device", which
                    // is only true while this is off. The second is because a
                    // ModelContainer cannot change its backing store after
                    // launch, so a user who flips this and sees nothing happen
                    // would reasonably think it broken.
                    Text(
                        syncEnabled
                            ? "Saved sequences are copied to your private iCloud database, so "
                                + "they appear on your other devices. Analysis still happens "
                                + "only on this device. Takes effect next time BOFFIN starts."
                            : "Everything stays on this device. Turn this on to have saved "
                                + "sequences appear on your other devices, through your own "
                                + "private iCloud database. Takes effect next time BOFFIN starts."
                    )
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func save(_ sequence: ProteinSequence) {
        // Saved once. Re-saving the same protein under the same name would
        // grow the list with duplicates that differ only by timestamp, which
        // reads as a bug rather than as history.
        if let existing = saved.first(where: { $0.letters == sequence.letters }) {
            existing.savedAt = Date()
            existing.name = sequence.name
            return
        }
        context.insert(
            SavedSequence(name: sequence.name, letters: sequence.letters))
    }
}

extension UserDefaults {
    /// The shared suite, so the app and its extensions read the same settings.
    static var boffinShared: UserDefaults {
        UserDefaults(suiteName: SharedInbox.appGroup) ?? .standard
    }
}
