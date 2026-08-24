//  Theme.swift
//  BoffinUI
//
//  Brand tokens carried from marcdeller.com.
//
//  Dark mode is first-class: structures sit on true black for OLED
//  presentation. Typography is the system font (San Francisco) for UI with a
//  monospaced face for sequences. Baloo 2 is reserved for the wordmark and icon
//  only: Dynamic Type and system font metrics matter more than brand fidelity
//  for body UI, so no web font is imported for text.

import SwiftUI

public enum Brand {
    /// Primary surface and headers.
    public static let navy = Color(hex: 0x1C_24_4B)
    /// Interactive elements and selection.
    public static let accent = Color(hex: 0x46_7F_F7)
    /// Presentation background: true black, not a dark grey, so OLED pixels
    /// are actually off behind a structure.
    public static let presentationBackground = Color.black
}

/// Semantic scientific palettes.
///
/// These are deliberately separate from the brand colours: a diverging scale
/// that happens to look like the brand is a coincidence, not a design, and
/// conflating them makes both harder to change.
public enum ScientificPalette {

    /// Diverging red to white to blue, centred at zero, for delta-LLR.
    ///
    /// Convention: negative (destabilising, depleted) is red, positive
    /// (tolerated, enriched) is blue. Fixed here so the heatmap, the logo and
    /// the structure overlay cannot disagree about sign.
    public static let llrNegative = Color(hex: 0xB2_18_2B)
    public static let llrNeutral = Color(hex: 0xF7_F7_F7)
    public static let llrPositive = Color(hex: 0x21_66_AC)

    /// Sequential scale for bounded continuous tracks (disorder, pLDDT).
    /// Viridis-like: perceptually uniform and safe for the common forms of
    /// colour vision deficiency.
    public static let sequential: [Color] = [
        Color(hex: 0x44_01_54),
        Color(hex: 0x3B_52_8B),
        Color(hex: 0x21_91_8C),
        Color(hex: 0x5E_C9_62),
        Color(hex: 0xFD_E7_25),
    ]

    /// Secondary structure categories (DSSP-style).
    public static func secondaryStructure(_ category: String) -> Color {
        switch category.uppercased() {
        case "H", "G", "I": Color(hex: 0xE4_1A_1C)  // helices
        case "E", "B": Color(hex: 0x37_7E_B8)  // strands
        case "T", "S": Color(hex: 0x4D_AF_4A)  // turns and bends
        default: Color(hex: 0x99_99_99)  // coil and unassigned
        }
    }
}

/// Typography. Sequence text is monospaced and scales with Dynamic Type, but
/// never below a legibility floor: an unreadable sequence is worse than a
/// sequence that ignores the user's smallest setting.
public enum Typography {
    public static let sequenceMinimumPointSize: CGFloat = 11

    public static func sequence(size: CGFloat) -> Font {
        .system(size: max(size, sequenceMinimumPointSize), weight: .regular, design: .monospaced)
    }
}

/// Spacing scale, in points. A four-point grid, so touch targets land on
/// multiples that align with the system's own metrics.
public enum Spacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32

    /// Minimum comfortable touch target per the Human Interface Guidelines.
    public static let minimumTouchTarget: CGFloat = 44
}

extension Color {
    /// Build from a 24-bit RGB literal, written as `0xRR_GG_BB`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
