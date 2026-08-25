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
        //
        // This reads the BUNDLED copy on purpose, and it has already earned it:
        // SPM's `.copy` of a directory does not reliably invalidate when a file
        // inside it changes, so the bundle can lag the source and the app can
        // ship a bridge that does not match the code next to it. The failure
        // reads as "no handler for listAssemblies" against a file that visibly
        // has one. `rm -rf .build` is the fix.
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
            ListAssembliesCommand().name,
            SetAssemblyCommand(assemblyId: nil).name,
            ExportImageCommand(width: 1920, height: 1080, transparent: false).name,
            ResetCameraCommand().name,
            ClearCommand().name,
        ]
        for name in names {
            #expect(
                source.contains("async \(name)("),
                "boffin-bridge.js has no handler for \(name)")
        }
    }

    /// `nil` means the deposited coordinates, and it has to survive encoding as
    /// an explicit null rather than being dropped: an absent key would leave the
    /// bridge unable to tell "asymmetric unit" from "no opinion".
    @Test("Returning to the asymmetric unit encodes as an explicit null")
    func assemblyNullIsExplicit() throws {
        let fields = try payload(SetAssemblyCommand(assemblyId: nil))
        #expect(fields.keys.contains("assemblyId"))
        #expect(fields["assemblyId"] is NSNull)

        let named = try payload(SetAssemblyCommand(assemblyId: "1"))
        #expect(named["assemblyId"] as? String == "1")
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

@Suite("Structure fetching")
struct StructureFetcherTests {

    /// Validation happens before the network, so a mistyped identifier is an
    /// immediate legible error rather than a round trip and a 404.
    @Test("A malformed identifier is refused without a request")
    func rejectsMalformedIdentifiers() async {
        let fetcher = StructureFetcher()
        for bad in ["", "1", "12345", "1u b", "../etc/passwd", "1ubq/../x"] {
            await #expect(throws: StructureFetchError.self) {
                _ = try await fetcher.rcsb(bad)
            }
        }
        for bad in ["", "P0/CG48", "P0 CG48", "../x"] {
            await #expect(throws: StructureFetchError.self) {
                _ = try await fetcher.alphaFold(bad)
            }
        }
    }

    /// A predicted model and an experimental structure put DIFFERENT numbers in
    /// the same column, and colouring one as the other makes a picture that is
    /// beautiful and wrong.
    @Test("A prediction says it is one, and says what its confidence column means")
    func predictionsAreLabelled() {
        let predicted = StructureSource.predicted(accession: "P0CG48")
        #expect(predicted.isPrediction)
        #expect(predicted.confidenceLabel.contains("pLDDT"))
        #expect(predicted.caveat?.contains("PREDICTED") == true)

        let experimental = StructureSource.experimental(pdbID: "1UBQ")
        #expect(!experimental.isPrediction)
        #expect(experimental.confidenceLabel.contains("B-factor"))
        #expect(experimental.caveat == nil)

        let bundled = StructureSource.bundled("1ubq.bcif")
        #expect(!bundled.isPrediction)
        #expect(bundled.caveat == nil)
    }
}

@Suite("Image export")
struct ExportImageTests {

    @Test("Requested sizes are clamped to what a mobile GPU will render")
    func sizesAreClamped() {
        // Mol* renders offscreen through a WebGL framebuffer, so the ceiling is
        // a hardware limit rather than a memory one. Exceeding it fails inside
        // the driver, where the error is a lost context and says nothing about
        // what asked for it. Refusing here costs a sentence; refusing there
        // costs the viewer.
        let huge = ExportImageCommand(width: 20_000, height: 9_000, transparent: false)
        #expect(huge.width == ExportImageCommand.maximumEdge)
        #expect(huge.height == ExportImageCommand.maximumEdge)

        let tiny = ExportImageCommand(width: 1, height: 0, transparent: true)
        #expect(tiny.width == ExportImageCommand.minimumEdge)
        #expect(tiny.height == ExportImageCommand.minimumEdge)

        let reasonable = ExportImageCommand(width: 1920, height: 1080, transparent: false)
        #expect(reasonable.width == 1920)
        #expect(reasonable.height == 1080)
    }

    @Test("A PNG's size is read from its own header, not from the renderer's report")
    func declaredSizeComesFromTheBytes() {
        // Those are two different claims and only one of them is in the file
        // the user sends to a journal. A caption saying 3840 wide, over a file
        // that is 1179 wide because the helper clamped, is a figure that will
        // come back from review.
        //
        // A minimal PNG header: the 8-byte signature, a length and "IHDR",
        // then width and height as big-endian UInt32.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0x00, 0x00, 0x00, 0x0D]
        bytes += Array("IHDR".utf8)
        bytes += [0x00, 0x00, 0x0F, 0x00]  // 3840
        bytes += [0x00, 0x00, 0x08, 0x70]  // 2160

        let image = StructureViewerModel.ExportedImage(
            data: Data(bytes), width: 1, height: 1)
        let declared = try? #require(image.declaredSize)
        #expect(declared?.width == 3840)
        #expect(declared?.height == 2160)
    }

    @Test("Bytes that are not a PNG declare no size at all")
    func nonPNGDeclaresNothing() {
        // Nil rather than a plausible number. A zero would be indistinguishable
        // from a real answer at a glance, and this value exists precisely to be
        // checked against a claim.
        let notAnImage = StructureViewerModel.ExportedImage(
            data: Data("this is not a png".utf8), width: 3840, height: 2160)
        #expect(notAnImage.declaredSize == nil)

        // A correct signature with the file cut short is the case that a naive
        // length check would let through into an index out of range.
        let truncated = StructureViewerModel.ExportedImage(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]),
            width: 0, height: 0)
        #expect(truncated.declaredSize == nil)
    }
}
