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

/// Ask what biological assemblies and models the loaded structure declares.
///
/// The deposited coordinates are the ASYMMETRIC UNIT, which is a
/// crystallographic convenience and frequently not the molecule: a dimer with
/// one chain in the asymmetric unit looks like a monomer until the assembly is
/// built, which is a picture of the wrong protein rather than an incomplete one.
public struct ListAssembliesCommand: ViewerCommand {
    public let name = "listAssemblies"
    public init() {}
}

/// Draw the interaction profile as dashed lines in the structure.
///
/// Endpoints are named by author chain, author residue number and atom name:
/// the fields BOFFIN reads out of the file itself. There is deliberately no
/// element index in this envelope, because an index means two implementations
/// agreeing about the order of atoms in a structure, and the two previous
/// attempts at this feature both foundered on exactly that assumption.
public struct DrawInteractionsCommand: ViewerCommand {
    public let name = "drawInteractions"
    public let lines: [Line]

    public struct Endpoint: Encodable, Sendable, Hashable {
        public let chain: String
        public let number: Int
        public let atom: String

        public init(chain: String, number: Int, atom: String) {
            self.chain = chain
            self.number = number
            self.atom = atom
        }
    }

    public struct Line: Encodable, Sendable, Hashable {
        public let a: Endpoint
        public let b: Endpoint
        public let kind: String

        public init(a: Endpoint, b: Endpoint, kind: String) {
            self.a = a
            self.b = b
            self.kind = kind
        }
    }

    public init(lines: [Line]) {
        self.lines = lines
    }
}

/// Remove the interaction overlay, leaving the structure alone.
public struct ClearInteractionsCommand: ViewerCommand {
    public let name = "clearInteractions"
    public init() {}
}

/// Render the current view as a PNG, at a size the viewport does not have.
///
/// This is the command that turns the viewer into something a figure comes out
/// of. A screenshot of a phone screen is 1179 pixels across and no journal will
/// take it; Mol* can render the same scene offscreen at an arbitrary size, so
/// a 300 dpi figure comes off a phone.
///
/// `transparent` is not a nicety either. A structure on an opaque white ground
/// cannot be composited onto a coloured panel or a poster without cutting it
/// out by hand, and cutting out antialiased edges by hand is how a figure
/// acquires a halo.
public struct ExportImageCommand: ViewerCommand {
    public let name = "exportImage"
    public let width: Int
    public let height: Int
    public let transparent: Bool

    /// The largest edge that will be attempted.
    ///
    /// Not a guess: Mol* renders offscreen through a WebGL framebuffer, and the
    /// ceiling on a mobile GPU is a hardware limit rather than a memory one, so
    /// exceeding it fails inside the driver where the error is unhelpful. 4096
    /// is the floor guaranteed by every device this app supports, and asking
    /// for more is refused here with a sentence rather than there with a
    /// context-lost.
    public static let maximumEdge = 4096

    /// The smallest, below which the request is a mistake rather than a choice.
    public static let minimumEdge = 128

    public init(width: Int, height: Int, transparent: Bool) {
        self.width = min(max(width, Self.minimumEdge), Self.maximumEdge)
        self.height = min(max(height, Self.minimumEdge), Self.maximumEdge)
        self.transparent = transparent
    }
}

/// Build a biological assembly, or return to the deposited coordinates.
public struct SetAssemblyCommand: ViewerCommand {
    public let name = "setAssembly"
    /// The assembly identifier, or `nil` for the asymmetric unit.
    public let assemblyId: String?

    public init(assemblyId: String?) {
        self.assemblyId = assemblyId
    }

    enum CodingKeys: String, CodingKey {
        case name
        case assemblyId
    }

    /// Encode `nil` as an explicit null rather than omitting the key.
    ///
    /// Swift's synthesised encoding drops a nil optional, which would leave the
    /// bridge unable to tell "build the asymmetric unit" from "the caller said
    /// nothing". Both currently take the same branch there, and relying on that
    /// is relying on a coincidence in someone else's `if`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(assemblyId, forKey: .assemblyId)
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
