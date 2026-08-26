//  RequiredColumnTests.swift
//  BoffinStructureTests
//
//  `AtomStoreError.missingColumn` was declared and never thrown. Every column
//  read in `AtomStore.from` reached for a fallback instead, which meant an
//  unreadable file loaded successfully and produced a store full of blanks.
//
//  Both halves are tested here, and the second half is the one that matters.
//  A guard that rejects a stripped file proves only that it rejects something;
//  it has to be shown not to reject the real files as well, or the fix trades
//  a silent wrong answer for a loud one.

import Foundation
import Testing

@testable import BoffinStructure

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures")
}

private func load(_ name: String) throws -> BinaryCIFFile {
    try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name)))
}

/// The same file with one column of `_atom_site` removed.
private func stripping(_ column: String, from file: BinaryCIFFile) throws
    -> BinaryCIFFile
{
    let site = try #require(file["_atom_site"])
    var columns = site.columns
    #expect(columns.removeValue(forKey: column) != nil,
            "the fixture has no \(column) to strip, so this proves nothing")
    var categories = file.categories
    categories["_atom_site"] = CIFCategory(
        name: site.name, rowCount: site.rowCount, columns: columns)
    return BinaryCIFFile(header: file.header, categories: categories)
}

@Suite("Required atom_site columns")
struct RequiredColumnTests {

    /// Every column the loader now insists on, and the failure each one
    /// prevents if it is allowed through instead.
    static let required: [(String, String)] = [
        ("Cartn_x", "no coordinates, so the store comes back empty"),
        ("Cartn_y", "no coordinates, so the store comes back empty"),
        ("Cartn_z", "no coordinates, so the store comes back empty"),
        ("type_symbol", "no elements, so nothing chemical can be decided"),
        ("label_atom_id", "no atom names, so no backbone or side chain"),
        ("label_comp_id", "no residue names, so every selection matches none"),
    ]

    @Test("A missing mandatory column is refused", arguments: required)
    func refused(column: String, consequence: String) throws {
        let stripped = try stripping(column, from: try load("1ubq.bcif"))
        #expect(throws: AtomStoreError.self) {
            _ = try AtomStore.from(stripped)
        }
    }

    @Test("Losing both sequence-number columns is refused")
    func bothSequenceNumbers() throws {
        var file = try load("1ubq.bcif")
        file = try stripping("auth_seq_id", from: file)
        // One alone is survivable and must stay so: the loader falls back.
        #expect(throws: Never.self) { _ = try AtomStore.from(file) }

        file = try stripping("label_seq_id", from: file)
        #expect(throws: AtomStoreError.self) { _ = try AtomStore.from(file) }
    }

    /// The half that keeps the guard honest.
    @Test("Every fixture still loads", arguments: [
        "1ubq.bcif", "1fha.bcif", "1l2y.bcif", "1a8o.bcif",
    ])
    func realFilesUnaffected(name: String) throws {
        let store = try AtomStore.from(try load(name))
        #expect(store.count > 0)
    }
}
