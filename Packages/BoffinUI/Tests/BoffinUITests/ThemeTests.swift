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
        // An unreadable sequence is worse than one that ignores the smallest
        // setting, so the floor clamps rather than the user's preference.
        #expect(
            Typography.sequence(size: 4)
                == Typography.sequence(size: Typography.sequenceMinimumPointSize))
    }

    @Test("The floor is applied to the scaled size, not the base size")
    func floorAppliesAfterScaling() {
        // This is the ordering that matters and it is easy to get backwards.
        // Applied to the BASE size, a user on the smallest text setting scales
        // 13 points down past 11 and the floor never fires, which is the one
        // setting it exists for. `SequenceFont` therefore passes the already
        // scaled value through here rather than clamping its input.
        #expect(Typography.sequencePointSize(4) == Typography.sequenceMinimumPointSize)
        #expect(Typography.sequencePointSize(9.5) == Typography.sequenceMinimumPointSize)
        #expect(Typography.sequencePointSize(13) == 13)
        #expect(Typography.sequencePointSize(40) == 40)
    }

    @Test("The fixed and scaling fonts are different things, deliberately")
    @MainActor
    func fixedAndScalingFontsAreBothAvailable() {
        // This is the test the old suite could not have: it asserted the floor
        // and said nothing about scaling, while the doc comment claimed
        // scaling that was never implemented. Naming both spellings here means
        // deleting either one breaks a test rather than a sentence.
        //
        // `sequence(size:)` is fixed and belongs inside a canvas, where a
        // residue label must fit the column it labels. `sequenceFont(size:)`
        // scales and belongs anywhere the text is read as text.
        let fixed = Typography.sequence(size: 13)
        #expect(fixed == Typography.sequence(size: 13))
        #expect(fixed != Typography.sequence(size: 20))
        _ = Text("MQIF").sequenceFont(size: 13)
    }
}
