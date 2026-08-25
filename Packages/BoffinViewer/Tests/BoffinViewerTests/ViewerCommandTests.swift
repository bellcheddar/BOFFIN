//  ViewerCommandTests.swift
//  BoffinViewerTests
//
//  The envelope, tested without a web view. What matters here is that a command
//  encodes to the shape `boffin-bridge.js` dispatches on, and that a value which
//  would be an injection if it were interpolated is carried as data instead.

import Foundation
import Testing

@testable import BoffinViewer

@Suite("Viewer command envelope")
struct ViewerCommandTests {

    private func payload<C: ViewerCommand>(_ command: C) throws -> [String: Any] {
        try ViewerBridge.payload(of: command)
    }

    @Test("A command encodes without its dispatch name in the payload")
    func payloadExcludesName() throws {
        let fields = try payload(SetRepresentationCommand(.cartoon))
        #expect(fields["representation"] as? String == "cartoon")
        #expect(fields["name"] == nil, "the dispatch key leaked into the payload")
    }

    /// Hard rule 3. A chain identifier containing a quote must be a chain that
    /// does not exist, not an injection: it travels as a JSON value and is never
    /// spliced into source.
    @Test("A hostile chain identifier survives as data, not as syntax")
    func noInjection() throws {
        let hostile = "A'); window.evil=1; ('"
        let command = PaintTrackCommand(
            title: "test",
            residues: [.init(chain: hostile, number: 1, colour: 0xFF0000)])
        let fields = try payload(command)
        let residues = try #require(fields["residues"] as? [[String: Any]])
        #expect(residues[0]["chain"] as? String == hostile)
        // Round-tripping through JSON is the whole guarantee: whatever the
        // string contains, it arrives as a string.
        let data = try JSONSerialization.data(withJSONObject: fields)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let residuesBack = try #require(back?["residues"] as? [[String: Any]])
        #expect(residuesBack[0]["chain"] as? String == hostile)
    }

    @Test("A structure is carried as base64 rather than as a file URL")
    func structureIsBytes() throws {
        let bytes = Data([0x83, 0xA7, 0x76, 0x65, 0x72])
        let command = LoadStructureCommand(data: bytes, format: .binaryCIF)
        let fields = try payload(command)
        #expect(fields["format"] as? String == "bcif")
        let encoded = try #require(fields["base64"] as? String)
        #expect(Data(base64Encoded: encoded) == bytes)
    }

    @Test("Every command's name matches a handler in the bridge")
    func namesMatchTheBridge() throws {
        // The JavaScript is in the same package, so the two halves can be
        // checked against each other rather than trusted to agree. A command
        // whose name has no handler is a silent no-op at runtime.
        let bridge = try #require(
            Bundle.module.url(forResource: "boffin-bridge", withExtension: "js")
                ?? Bundle.module.url(
                    forResource: "boffin-bridge", withExtension: "js",
                    subdirectory: "Web"))
        let source = try String(contentsOf: bridge, encoding: .utf8)

        let names = [
            PingCommand().name,
            LoadStructureCommand(data: Data(), format: .mmCIF).name,
            SetRepresentationCommand(.cartoon).name,
            SetColourThemeCommand(.chain).name,
            PaintTrackCommand(title: "", residues: []).name,
            ResetCameraCommand().name,
            ClearCommand().name,
        ]
        for name in names {
            #expect(
                source.contains("async \(name)("),
                "boffin-bridge.js has no handler for \(name)")
        }
    }

    @Test("An event decodes from the bridge's tagged union")
    func eventDecoding() {
        #expect(ViewerEvent(message: ["kind": "ready"]) == .ready)
        #expect(
            ViewerEvent(message: ["kind": "loaded", "atomCount": 660])
                == .loaded(atomCount: 660))
        #expect(
            ViewerEvent(message: ["kind": "picked", "chain": "A", "number": 145])
                == .picked(chainID: "A", authorNumber: 145))
        #expect(
            ViewerEvent(message: ["kind": "failed", "message": "boom"])
                == .failed(message: "boom"))
        // Unknown kinds and malformed payloads are nil rather than a default
        // event: a bridge that invents an event is worse than one that drops it.
        #expect(ViewerEvent(message: ["kind": "nonsense"]) == nil)
        #expect(ViewerEvent(message: ["kind": "picked"]) == nil)
        #expect(ViewerEvent(message: [:]) == nil)
    }

    @Test("The vendored viewer is present and refers to no network host")
    func offline() throws {
        let bundle = Bundle.module
        for name in ["molstar.js", "molstar.css", "boffin-bridge.js"] {
            let parts = name.split(separator: ".")
            let url =
                bundle.url(
                    forResource: String(parts[0]), withExtension: String(parts[1]),
                    subdirectory: "Web")
                ?? bundle.url(
                    forResource: String(parts[0]), withExtension: String(parts[1]))
            #expect(url != nil, "\(name) is missing from the bundle")
        }

        // Hard rule 2. The page itself must not reference a CDN; the vendored
        // Mol* build mentions URLs in its own data-source configuration, which
        // is inert unless a fetch is requested, but OUR page must be clean.
        let page = try #require(
            bundle.url(
                forResource: "boffin-viewer", withExtension: "html", subdirectory: "Web")
                ?? bundle.url(forResource: "boffin-viewer", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
    }
}
