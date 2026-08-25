//  PyMOLScript.swift
//  BoffinStructure
//
//  Writing and reading `.pml`, so a scene built on a phone opens on a desktop.
//
//  The export is the differentiator the build plan asks not to drop, and the
//  import is the half that has to fail loudly. A `.pml` file is a program: it
//  can do things BOFFIN has no equivalent for, and silently ignoring a command
//  produces a scene that is subtly not the one the file describes. Unsupported
//  commands are collected and reported, never skipped.

import Foundation

/// One named scene: what is shown, how, and from where.
public struct Scene: Sendable, Hashable, Identifiable {
    public let name: String
    /// The selection expression this scene highlights, if any.
    public let selection: String?
    public let representation: String
    public let colourTheme: String
    /// Presenter notes, which travel with the scene and not with the file name.
    public let notes: String

    public var id: String { name }

    public init(
        name: String, selection: String? = nil, representation: String = "cartoon",
        colourTheme: String = "chain", notes: String = ""
    ) {
        self.name = name
        self.selection = selection
        self.representation = representation
        self.colourTheme = colourTheme
        self.notes = notes
    }
}

/// What an import understood, and what it did not.
public struct PyMOLImport: Sendable, Hashable {
    public let scenes: [Scene]
    /// Commands with no BOFFIN equivalent, verbatim and with their line number.
    ///
    /// Reported rather than dropped. A `.pml` file is a program, and a viewer
    /// that quietly ignores a third of it draws a scene that is subtly not the
    /// one the file describes.
    public let unsupported: [(line: Int, command: String)]

    public static func == (lhs: PyMOLImport, rhs: PyMOLImport) -> Bool {
        lhs.scenes == rhs.scenes && lhs.unsupported.map(\.line) == rhs.unsupported.map(\.line)
            && lhs.unsupported.map(\.command) == rhs.unsupported.map(\.command)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scenes)
    }
}

public enum PyMOLScript {

    /// Commands BOFFIN understands on import.
    static let understood: Set<String> = [
        "load", "hide", "show", "color", "select", "set_view", "orient", "scene",
        "bg_color", "png", "deselect", "zoom", "reinitialize",
    ]

    /// Representations BOFFIN names differently from PyMOL.
    ///
    /// One table, both directions, so the two cannot drift into disagreeing
    /// about what "surface" means.
    static let representations: [(boffin: String, pymol: String)] = [
        ("cartoon", "cartoon"),
        ("ball-and-stick", "sticks"),
        ("spacefill", "spheres"),
        ("molecular-surface", "surface"),
        ("backbone", "ribbon"),
        ("line", "lines"),
    ]

    static func pymolRepresentation(for boffin: String) -> String {
        representations.first { $0.boffin == boffin }?.pymol ?? "cartoon"
    }

    static func boffinRepresentation(for pymol: String) -> String {
        representations.first { $0.pymol == pymol }?.boffin ?? "cartoon"
    }

    /// Write a deck of scenes as a PyMOL script.
    ///
    /// - Parameters:
    ///   - scenes: the deck, in order.
    ///   - structureName: the object name to load and act on.
    /// - Returns: the script text.
    public static func export(_ scenes: [Scene], structureName: String) -> String {
        var lines: [String] = []
        lines.append("# Written by BOFFIN")
        lines.append("#")
        lines.append("# Scene notes are preserved as comments: PyMOL has no field for")
        lines.append("# them, and dropping them would lose the half of a deck that")
        lines.append("# explains the other half.")
        lines.append("")
        lines.append("load \(structureName).cif, \(structureName)")
        lines.append("hide everything")
        lines.append("bg_color white")
        lines.append("")

        for (index, scene) in scenes.enumerated() {
            let key = safeName(scene.name)
            lines.append("# --- \(scene.name) ---")
            if !scene.notes.isEmpty {
                for note in scene.notes.split(separator: "\n") {
                    lines.append("# \(note)")
                }
            }
            lines.append("hide everything")
            if let selection = scene.selection, !selection.isEmpty {
                lines.append("select \(key)_sel, \(selection)")
                lines.append("show \(pymolRepresentation(for: scene.representation)), \(key)_sel")
                lines.append("orient \(key)_sel")
            } else {
                lines.append(
                    "show \(pymolRepresentation(for: scene.representation)), \(structureName)")
                lines.append("orient \(structureName)")
            }
            lines.append("color \(pymolColour(for: scene.colourTheme)), \(structureName)")
            lines.append("scene \(key), store")
            if index < scenes.count - 1 { lines.append("") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// PyMOL's nearest colouring command for one of BOFFIN's themes.
    ///
    /// Deliberately lossy and named as such: PyMOL's `spectrum` and `util.cbc`
    /// are not the same functions BOFFIN uses, so this reproduces the INTENT of
    /// a scene rather than its exact pixels.
    static func pymolColour(for theme: String) -> String {
        switch theme {
        case "chain-id", "chain": "grey80"
        case "element-symbol", "element": "atomic"
        case "secondary-structure": "ss"
        case "uncertainty": "b"
        default: "grey70"
        }
    }

    /// A PyMOL object name: letters, digits and underscores.
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let text = String(cleaned)
        // A name starting with a digit is not a valid PyMOL identifier.
        return text.first?.isNumber == true ? "s_\(text)" : (text.isEmpty ? "scene" : text)
    }

    /// Read a PyMOL script, reporting what could not be represented.
    public static func importScript(_ text: String) -> PyMOLImport {
        var scenes: [Scene] = []
        var unsupported: [(line: Int, command: String)] = []

        var selection: String?
        var representation = "cartoon"
        var colourTheme = "chain"
        var notes: [String] = []

        for (offset, rawLine) in text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let note = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !note.isEmpty, !note.hasPrefix("---"), !note.hasPrefix("Written by") {
                    notes.append(note)
                }
                continue
            }

            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let command = parts[0].lowercased()
            let arguments = parts.count > 1 ? parts[1] : ""

            guard understood.contains(command) else {
                unsupported.append((offset + 1, line))
                continue
            }

            switch command {
            case "select":
                // `select name, expression`
                let pieces = arguments.split(separator: ",", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pieces.count == 2 { selection = pieces[1] }
            case "show":
                let pieces = arguments.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if let first = pieces.first, !first.isEmpty {
                    representation = boffinRepresentation(for: first.lowercased())
                }
            case "color":
                let pieces = arguments.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if let first = pieces.first {
                    colourTheme = boffinColour(for: first.lowercased())
                }
            case "scene":
                // `scene name, store` closes the scene being built.
                let pieces = arguments.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let name = pieces.first ?? "scene \(scenes.count + 1)"
                scenes.append(
                    Scene(
                        name: name, selection: selection, representation: representation,
                        colourTheme: colourTheme,
                        notes: notes.joined(separator: "\n")))
                selection = nil
                notes = []
            default:
                break
            }
        }

        return PyMOLImport(scenes: scenes, unsupported: unsupported)
    }

    static func boffinColour(for pymol: String) -> String {
        switch pymol {
        case "atomic": "element-symbol"
        case "ss": "secondary-structure"
        case "b": "uncertainty"
        default: "chain-id"
        }
    }
}
