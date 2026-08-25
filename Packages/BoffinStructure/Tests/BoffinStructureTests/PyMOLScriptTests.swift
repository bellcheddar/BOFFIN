//  PyMOLScriptTests.swift
//  BoffinStructureTests
//
//  Round-tripping matters, and failing loudly matters more. A `.pml` file is a
//  program: a viewer that quietly ignores the commands it does not understand
//  draws a scene that is subtly not the one the file describes, and nobody can
//  see which parts were dropped.

import Testing

@testable import BoffinStructure

@Suite("PyMOL script")
struct PyMOLScriptTests {

    private let deck = [
        Scene(
            name: "Overview", selection: nil, representation: "cartoon",
            colourTheme: "chain-id", notes: "Start wide."),
        Scene(
            name: "ATP site", selection: "byres (polymer within 5 of organic)",
            representation: "ball-and-stick", colourTheme: "element-symbol",
            notes: "The hinge is Glu81 to Leu83.\nMention the gatekeeper."),
    ]

    @Test("An exported script loads, shows and stores each scene in order")
    func exportShape() {
        let script = PyMOLScript.export(deck, structureName: "1hck")
        #expect(script.contains("load 1hck.cif, 1hck"))
        #expect(script.contains("scene Overview, store"))
        #expect(script.contains("scene ATP_site, store"))
        // The selection travels verbatim: BOFFIN's language is PyMOL's here,
        // which is the entire reason for choosing that syntax.
        #expect(script.contains("byres (polymer within 5 of organic)"))
        // Stored in deck order.
        let overview = script.range(of: "scene Overview, store")
        let site = script.range(of: "scene ATP_site, store")
        #expect(overview != nil && site != nil)
        #expect(overview!.lowerBound < site!.lowerBound)
    }

    /// PyMOL has no field for presenter notes, and dropping them would lose the
    /// half of a deck that explains the other half.
    @Test("Notes survive as comments, including multiple lines")
    func notesSurvive() {
        let script = PyMOLScript.export(deck, structureName: "1hck")
        #expect(script.contains("# Start wide."))
        #expect(script.contains("# The hinge is Glu81 to Leu83."))
        #expect(script.contains("# Mention the gatekeeper."))
    }

    @Test("Scene names become valid PyMOL identifiers")
    func nameSafety() {
        #expect(PyMOLScript.safeName("ATP site") == "ATP_site")
        #expect(PyMOLScript.safeName("2. the hinge") == "s_2__the_hinge")
        #expect(PyMOLScript.safeName("") == "scene")
        #expect(PyMOLScript.safeName("a-b/c") == "a_b_c")
    }

    @Test("A deck survives a round trip through the script")
    func roundTrip() {
        let script = PyMOLScript.export(deck, structureName: "1hck")
        let imported = PyMOLScript.importScript(script)

        #expect(imported.unsupported.isEmpty, "our own output was not understood")
        #expect(imported.scenes.count == 2)
        #expect(imported.scenes[0].name == "Overview")
        #expect(imported.scenes[1].name == "ATP_site")
        #expect(imported.scenes[1].selection == "byres (polymer within 5 of organic)")
        #expect(imported.scenes[1].representation == "ball-and-stick")
        #expect(imported.scenes[1].colourTheme == "element-symbol")
        #expect(imported.scenes[1].notes.contains("gatekeeper"))
    }

    /// The half that has to fail loudly.
    @Test("Commands with no equivalent are reported with their line, not skipped")
    func unsupportedIsReported() {
        let script = """
            load 1hck.cif, 1hck
            hide everything
            set ray_trace_mode, 1
            show cartoon, 1hck
            ramp_new proximity, 1hck, [0, 5], [blue, red]
            scene one, store
            python
            print('hello')
            python end
            """
        let imported = PyMOLScript.importScript(script)
        #expect(imported.scenes.count == 1)

        let reported = imported.unsupported.map(\.command)
        #expect(reported.contains { $0.hasPrefix("set ray_trace_mode") })
        #expect(reported.contains { $0.hasPrefix("ramp_new") })
        #expect(reported.contains { $0.hasPrefix("python") })
        // Line numbers, so a user can find them rather than being told a count.
        let rayTrace = imported.unsupported.first { $0.command.hasPrefix("set ray") }
        #expect(rayTrace?.line == 3)
    }

    @Test("Representation names map both ways without drifting")
    func representationMapping() {
        for (boffin, pymol) in PyMOLScript.representations {
            #expect(PyMOLScript.pymolRepresentation(for: boffin) == pymol)
            #expect(PyMOLScript.boffinRepresentation(for: pymol) == boffin)
        }
        // An unknown name falls back rather than producing an invalid script.
        #expect(PyMOLScript.pymolRepresentation(for: "nonsense") == "cartoon")
        #expect(PyMOLScript.boffinRepresentation(for: "nonsense") == "cartoon")
    }

    @Test("An empty deck exports a script that still loads the structure")
    func emptyDeck() {
        let script = PyMOLScript.export([], structureName: "1ubq")
        #expect(script.contains("load 1ubq.cif, 1ubq"))
        #expect(!script.contains("scene "))
        #expect(PyMOLScript.importScript(script).scenes.isEmpty)
    }
}
