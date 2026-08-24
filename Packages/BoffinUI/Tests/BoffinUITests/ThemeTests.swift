//  ThemeTests.swift
//  BoffinUITests

import SwiftUI
import Testing

@testable import BoffinUI

@Suite("Design tokens")
struct ThemeTests {

    @Test("The hex initialiser decodes channels in the right order")
    func hexInitialiserDecodesChannels() throws {
        let resolved = Color(hex: 0x46_7F_F7).resolve(in: EnvironmentValues())
        #expect(abs(resolved.red - 0x46 / 255.0) < 0.01)
        #expect(abs(resolved.green - 0x7F / 255.0) < 0.01)
        #expect(abs(resolved.blue - 0xF7 / 255.0) < 0.01)
    }

    @Test("Sequence type never falls below the legibility floor")
    func sequenceTypeHasFloor() {
        // Dynamic Type may scale a sequence down, but an unreadable sequence
        // is worse than one that ignores the smallest setting.
        #expect(
            Typography.sequence(size: 4)
                == Typography.sequence(size: Typography.sequenceMinimumPointSize))
    }
}
