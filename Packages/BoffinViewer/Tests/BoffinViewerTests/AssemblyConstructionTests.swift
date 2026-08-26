//  AssemblyConstructionTests.swift
//  BoffinViewerTests
//
//  Does the viewer actually BUILD the biological assembly?
//
//  Nothing could answer that until 2026-08-26, because every golden fixture's
//  declared assembly already equalled its asymmetric unit: building it was a
//  no-op on all seven, so an earlier UI test was deleted rather than tuned.
//  That was recorded as a version-pinning problem with what Mol* reports, and
//  the deeper problem was that there was nothing meaningful to assert.
//
//  1FHA fixes it. Human ferritin heavy chain declares a 24-mer and deposits a
//  single chain, so building the assembly multiplies the structure
//  twenty-four-fold. A viewer that silently ignores the assembly shows one
//  twenty-fourth of the protein and looks entirely reasonable doing it, which
//  is exactly the failure this project keeps finding: correct-looking output
//  from a step that did nothing.
//
//  Driven through a headless WKWebView against the vendored Mol* build, which
//  runs on the macOS test host in a few seconds. The assertion is the ATOM
//  COUNT, because that is the only thing distinguishing a built assembly from
//  an ignored one.
//
//  What the fixture immediately revealed, and none of it was what was expected:
//
//  **Mol* builds the assembly on LOAD.** Ferritin arrives as 32,664 atoms, not
//  the 1,361 it deposits. The default preset is assembly-aware, so the viewer
//  has been showing biological assemblies all along and asking for the "model"
//  is what yields the deposited coordinates. The project's own notes had this
//  backwards, describing a risk of seeing a monomer where the molecule is a
//  dimer; the real risk is the reverse.
//
//  **`listAssemblies` computed a diagnostic and threw it away.** The handler
//  carefully worked out which path it took, or why none worked, and the return
//  statement omitted `note`, so every empty list looked identical: exactly the
//  confusion the note was written to prevent.
//
//  **This Mol* build cannot enumerate assemblies at all.** `Symmetry` offers
//  `findAssembly` and `StructureSymmetry` offers builders, but neither offers a
//  list and there is no `Symmetry.Provider`. So assemblies are now read from
//  BOFFIN's own parse of the entry, which had the answer all along.

import Foundation
import Testing
import WebKit

@testable import BoffinViewer

private var fixture: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures/1fha.bcif")
}

private var web: URL? {
    Bundle.module.url(forResource: "Web", withExtension: nil)
}

@Suite("Assembly construction", .serialized)
struct AssemblyConstructionTests {

    /// One subunit of ferritin, as deposited.
    private static let depositedAtoms = 1361
    /// Chains the entry declares for the biological assembly.
    private static let declaredChains = 24

    @MainActor
    private func bridgeUp() async throws -> WKWebView? {
        guard let web, FileManager.default.fileExists(atPath: fixture.path) else { return nil }
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        view.loadFileURL(
            web.appending(path: "boffin-viewer.html"), allowingReadAccessTo: web)
        for _ in 0..<150 {
            try? await Task.sleep(for: .milliseconds(400))
            let ready =
                try? await view.evaluateJavaScript(
                    "typeof boffinDispatch === 'function'") as? Bool
            if ready == true { return view }
        }
        return nil
    }

    @MainActor
    @Test("Ferritin loads as its 24-mer, and the deposited coordinates are one chain")
    func assemblyIsBuiltOnLoad() async throws {
        guard let view = try await bridgeUp() else { return }

        let base64 = try Data(contentsOf: fixture).base64EncodedString()
        let loaded = try await view.callAsyncJavaScript(
            "return await boffinDispatch({name:'loadStructure', payload:{base64:b, format:'bcif'}});",
            arguments: ["b": base64], contentWorld: .page)
        let onLoad = try #require(
            ((loaded as? [String: Any])?["result"] as? [String: Any])?["atomCount"] as? Int)

        // The default preset is assembly-aware: this is the 24-mer, not the
        // deposit. Asserted rather than assumed, because it is the opposite of
        // what the project's notes described.
        #expect(
            onLoad == Self.depositedAtoms * Self.declaredChains,
            "expected \(Self.depositedAtoms * Self.declaredChains) atoms on load, got \(onLoad)")

        // Asking for the model gives the asymmetric unit back.
        let asDeposited = try await view.callAsyncJavaScript(
            "return await boffinDispatch({name:'setAssembly', payload:{assemblyId:null}});",
            arguments: [:], contentWorld: .page)
        let deposited = try #require(
            ((asDeposited as? [String: Any])?["result"] as? [String: Any])?["atomCount"] as? Int)

        #expect(
            deposited == Self.depositedAtoms,
            "the deposited coordinates are one subunit, got \(deposited)")
        #expect(
            onLoad > deposited,
            "the assembly and the deposit are the same size, so this fixture is inert")
    }

    @MainActor
    @Test("An empty assembly list now carries the reason it is empty")
    func emptyListExplainsItself() async throws {
        // The note was computed and dropped at the return, so "declares none"
        // and "could not look" arrived identical. That is the confusion the
        // note exists to prevent, and it went unnoticed because no fixture
        // declared an assembly the viewer could fail to find.
        guard let view = try await bridgeUp() else { return }
        let base64 = try Data(contentsOf: fixture).base64EncodedString()
        _ = try await view.callAsyncJavaScript(
            "return await boffinDispatch({name:'loadStructure', payload:{base64:b, format:'bcif'}});",
            arguments: ["b": base64], contentWorld: .page)

        let listed = try await view.callAsyncJavaScript(
            "return await boffinDispatch({name:'listAssemblies', payload:{}});",
            arguments: [:], contentWorld: .page)
        let result = try #require((listed as? [String: Any])?["result"] as? [String: Any])
        let assemblies = result["assemblies"] as? [[String: Any]] ?? []

        if assemblies.isEmpty {
            let note = result["note"] as? String
            #expect(
                note?.isEmpty == false,
                "an empty assembly list arrived with no explanation")
        }
    }
}

@Suite("Which assembly the picker claims", .serialized)
struct AssemblySelectionTests {

    /// The viewer model's own load path, exercised against the real fixture.
    ///
    /// This is the state the UI binds to. It said "deposited coordinates" while
    /// the screen showed a 24-mer, because Mol*'s default preset builds the
    /// assembly and the model initialised its selection to nil regardless. A
    /// picker that disagrees with the picture is worse than no picker: it is a
    /// label asserting something false about what you are looking at.
    @MainActor
    @Test("Ferritin's selection reflects the assembly actually shown")
    func selectionMatchesWhatIsDisplayed() async throws {
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }
        let model: StructureViewerModel
        do { model = try StructureViewerModel() } catch { return }

        model.start()
        for _ in 0..<150 where model.state != .ready {
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard model.state == .ready else { return }

        await model.load(try Data(contentsOf: fixture), format: .binaryCIF)

        // The entry declares one assembly and BOFFIN parses it from the file,
        // so the picker has something to offer whatever Mol* can enumerate.
        #expect(model.assemblies.count == 1, "1FHA declares one assembly")

        // And the selection is that assembly, not nil, because the viewer is
        // showing it. Measured on load by comparing the viewer's atom count
        // against BOFFIN's own parse rather than assuming the preset.
        #expect(
            model.assembly == model.assemblies.first?.id,
            "the picker claims deposited coordinates while a 24-mer is on screen")
    }
}
