//  AtomStoreTests.swift
//  BoffinStructureTests

import Testing

@testable import BoffinStructure

@Suite("Atom store")
struct AtomStoreTests {

    @Test("An empty store reports zero atoms")
    func emptyStoreIsEmpty() {
        #expect(AtomStore().count == 0)
    }
}
