//  ViewerCommand.swift
//  BoffinViewer
//
//  The typed command envelope for the Swift to JavaScript bridge.
//
//  Hard rule 3: never string-interpolate into JavaScript. Every command is a
//  value, JSON-encoded, handed to `callAsyncJavaScript` as an argument rather
//  than spliced into source. A chain identifier containing a quote should be a
//  chain that does not exist, not an injection.
//
//  A future native Metal renderer implements the same protocol, so the SwiftUI
//  layer above does not change when the renderer does.

import BoffinCore
import BoffinStructure
import Foundation

/// A command sent from Swift to the viewer.
public protocol ViewerCommand: Encodable, Sendable {
    /// The dispatch key. Must match a handler in `boffin-bridge.js`.
    var name: String { get }
}

/// An event sent from the viewer back to Swift: picks, hovers, load completion.
public enum ViewerEvent: Sendable, Hashable {
    case ready
    case loaded(atomCount: Int)
    case picked(chainID: String, authorNumber: Int)
    case hovered(chainID: String, authorNumber: Int)
    case failed(message: String)

    /// Decode one event from the bridge's tagged union.
    public init?(message: [String: Any]) {
        switch message["kind"] as? String {
        case "ready":
            self = .ready
        case "loaded":
            self = .loaded(atomCount: message["atomCount"] as? Int ?? 0)
        case "picked":
            guard let chain = message["chain"] as? String,
                let number = message["number"] as? Int
            else { return nil }
            self = .picked(chainID: chain, authorNumber: number)
        case "hovered":
            guard let chain = message["chain"] as? String,
                let number = message["number"] as? Int
            else { return nil }
            self = .hovered(chainID: chain, authorNumber: number)
        case "failed":
            self = .failed(message: message["message"] as? String ?? "unknown error")
        default:
            return nil
        }
    }
}

/// How a structure is drawn.
public enum ViewerRepresentation: String, Sendable, CaseIterable, Codable {
    case cartoon
    case ballAndStick = "ball-and-stick"
    case spacefill
    case surface = "molecular-surface"
    case backbone
    case line

    public var name: String {
        switch self {
        case .cartoon: "Cartoon"
        case .ballAndStick: "Ball and stick"
        case .spacefill: "Spacefill"
        case .surface: "Surface"
        case .backbone: "Backbone"
        case .line: "Lines"
        }
    }

    /// Representations cheap enough for a very large assembly.
    ///
    /// A surface over 100,000 atoms is not slow, it is a hung web view, so the
    /// guardrail picks from this list instead of asking.
    public static let coarse: [ViewerRepresentation] = [.backbone, .line]
}

/// A built-in colour theme.
public enum ViewerColourTheme: String, Sendable, CaseIterable, Codable {
    case chain = "chain-id"
    case element = "element-symbol"
    case secondaryStructure = "secondary-structure"
    case bFactor = "uncertainty"
    case hydrophobicity
    case uniform

    public var name: String {
        switch self {
        case .chain: "Chain"
        case .element: "Element"
        case .secondaryStructure: "Secondary structure"
        case .bFactor: "B-factor or pLDDT"
        case .hydrophobicity: "Hydrophobicity"
        case .uniform: "Uniform"
        }
    }
}

// MARK: - Commands

public struct PingCommand: ViewerCommand {
    public let name = "ping"
    public init() {}
}

/// Load a structure from bytes the app has already read.
///
/// Base64 rather than a file URL: handing the web view a URL means granting it
/// read access to a directory, and the app has the bytes in hand either way.
public struct LoadStructureCommand: ViewerCommand {
    public let name = "loadStructure"
    public let base64: String
    public let format: String

    public init(data: Data, format: StructureFormat) {
        self.base64 = data.base64EncodedString()
        self.format = format.rawValue
    }

    public enum StructureFormat: String, Sendable {
        case binaryCIF = "bcif"
        case mmCIF = "mmcif"
    }
}

public struct SetRepresentationCommand: ViewerCommand {
    public let name = "setRepresentation"
    public let representation: String

    public init(_ representation: ViewerRepresentation) {
        self.representation = representation.rawValue
    }
}

public struct SetColourThemeCommand: ViewerCommand {
    public let name = "setColourTheme"
    public let theme: String

    public init(_ theme: ViewerColourTheme) {
        self.theme = theme.rawValue
    }
}

/// Paint a `ResidueTrack` onto the structure.
///
/// The single most compelling thing the viewer does, and the reason the bridge
/// carries a colour per residue rather than the name of a theme: the colours
/// come from BOFFIN's own analysis and Mol* has never heard of them.
public struct PaintTrackCommand: ViewerCommand {
    public let name = "paintTrack"
    public let title: String
    public let residues: [Residue]
    /// Colour for residues the track says nothing about, as 0xRRGGBB.
    public let fallbackColour: Int

    public struct Residue: Encodable, Sendable, Hashable {
        public let chain: String
        public let number: Int
        public let colour: Int

        public init(chain: String, number: Int, colour: Int) {
            self.chain = chain
            self.number = number
            self.colour = colour
        }
    }

    public init(title: String, residues: [Residue], fallbackColour: Int = 0x9E9E9E) {
        self.title = title
        self.residues = residues
        self.fallbackColour = fallbackColour
    }
}

public struct ResetCameraCommand: ViewerCommand {
    public let name = "resetCamera"
    public init() {}
}

public struct ClearCommand: ViewerCommand {
    public let name = "clear"
    public init() {}
}
