//  StructureViewer.swift
//  BoffinViewer
//
//  The SwiftUI surface over the bridge.
//
//  The view owns nothing but a `ViewerBridge`. Every decision about what is
//  drawn is a command, so the same view drives a future native renderer without
//  changing, and so the whole of the viewer's behaviour is inspectable as a
//  sequence of values rather than as a pile of side effects on a web view.

import BoffinCore
import BoffinStructure
import Foundation
import SwiftUI
import WebKit

/// What the viewer is doing.
public enum ViewerState: Sendable, Hashable {
    case idle
    case starting
    case ready
    case loading
    case loaded(atomCount: Int)
    case failed(String)
}

/// Drives one structure viewer.
@MainActor
@Observable
public final class StructureViewerModel {

    public private(set) var state: ViewerState = .idle
    public private(set) var representation: ViewerRepresentation = .cartoon
    public private(set) var colourTheme: ViewerColourTheme = .chain
    /// Set when the guardrail has coarsened the view, so the UI can say so
    /// rather than leaving a user wondering why the cartoon went away.
    public private(set) var guardrailNotice: String?

    /// Where the loaded structure came from, so the UI can label a prediction.
    public private(set) var source: StructureSource?

    /// Biological assemblies the structure declares, empty when it declares
    /// none.
    public private(set) var assemblies: [Assembly] = []
    /// The assembly currently built, or `nil` for the deposited coordinates.
    public private(set) var assembly: String?
    /// Set when the assembly list is empty for a reason other than the
    /// structure declaring none.
    public private(set) var assemblyNote: String?
    /// How many models the file holds. More than one is an NMR ensemble.
    public private(set) var modelCount: Int = 1

    public struct Assembly: Sendable, Hashable, Identifiable, Decodable {
        public let id: String
        public let details: String
    }

    /// The last residue tapped in the structure, in the structure's own author
    /// numbering.
    ///
    /// Author numbering, not a sequence index, because that is what the
    /// structure knows and what a paper quotes. Translating it into the user's
    /// sequence is the app's job and needs the alignment.
    public private(set) var selection: (chain: String, authorNumber: Int)?

    /// Above this, a `WKWebView` on a phone stops being slow and starts being
    /// hung, so the viewer coarsens itself rather than trying.
    ///
    /// 100,000 is the build plan's figure. The ribosome fixture is 127,000
    /// atoms, which is exactly the case it exists for.
    public static let coarseAboveAtoms = 100_000

    public let bridge: ViewerBridge

    public init(bridge: ViewerBridge) {
        self.bridge = bridge
    }

    public convenience init() throws {
        self.init(bridge: ViewerBridge(resources: try ViewerResources.bundled()))
    }

    /// Start the page and watch for events.
    public func start() {
        guard case .idle = state else { return }
        state = .starting
        bridge.start()
        Task { [bridge] in
            for await event in bridge.events {
                switch event {
                case .ready:
                    if case .starting = self.state { self.state = .ready }
                case .loaded(let count):
                    self.state = .loaded(atomCount: count)
                case .failed(let message):
                    self.state = .failed(message)
                case .picked(let chain, let number):
                    self.selection = (chain, number)
                case .hovered:
                    break
                }
            }
        }
    }

    /// Fetch a structure and load it.
    ///
    /// Network work, so it is additive: a failure sets the state and leaves
    /// whatever was already loaded alone.
    public func fetch(_ work: @Sendable () async throws -> FetchedStructure) async {
        state = .loading
        do {
            let fetched = try await work()
            await load(fetched.data, format: fetched.format, source: fetched.source)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Load a structure and apply the guardrail if it is a large one.
    public func load(
        _ data: Data, format: LoadStructureCommand.StructureFormat,
        source: StructureSource? = nil
    ) async {
        state = .loading
        self.source = source
        do {
            struct Reply: Decodable { let atomCount: Int }
            let reply = try await bridge.send(
                LoadStructureCommand(data: data, format: format), expecting: Reply.self)
            state = .loaded(atomCount: reply.atomCount)

            if reply.atomCount > Self.coarseAboveAtoms {
                // Coarsen FIRST and tell the user afterwards. Asking would mean
                // rendering the expensive thing to find out it was expensive.
                try await bridge.send(SetRepresentation(.backbone))
                representation = .backbone
                guardrailNotice =
                    "\(reply.atomCount.formatted()) atoms: showing a backbone trace. "
                    + "A cartoon or a surface at this size does not render slowly, it "
                    + "stops responding."
            } else {
                guardrailNotice = nil
                try await bridge.send(SetRepresentation(representation))
            }
            try await bridge.send(SetColourThemeCommand(colourTheme))

            struct Declared: Decodable {
                let assemblies: [Assembly]
                let models: Int
                /// Why the list is empty, when it is empty for a reason other
                /// than the structure declaring none.
                let note: String?
            }
            let declared = try await bridge.send(
                ListAssembliesCommand(), expecting: Declared.self)
            assemblies = declared.assemblies
            modelCount = declared.models
            assembly = nil
            // An empty list because the structure has no assemblies is a fact;
            // an empty list because the viewer could not look is a defect, and
            // the two must not read the same. The note carries which it was.
            assemblyNote = declared.assemblies.isEmpty ? declared.note : nil
        } catch {
            state = .failed(String(describing: error))
        }
    }

    public func set(representation: ViewerRepresentation) async {
        self.representation = representation
        try? await bridge.send(SetRepresentation(representation))
    }

    public func set(colourTheme: ViewerColourTheme) async {
        self.colourTheme = colourTheme
        try? await bridge.send(SetColourThemeCommand(colourTheme))
    }

    /// Paint a residue track onto the structure.
    ///
    /// The mapping from a track's residue INDEX to a structure's author number
    /// is the caller's job, because only the app can see both. Handing this a
    /// list of indices and hoping they line up is the classic way to colour the
    /// right structure with the wrong data.
    public func paint(
        title: String, residues: [PaintTrackCommand.Residue]
    ) async throws {
        try await bridge.send(PaintTrackCommand(title: title, residues: residues))
    }

    /// Build a biological assembly, or return to the deposited coordinates.
    public func set(assembly identifier: String?) async {
        do {
            struct Reply: Decodable { let atomCount: Int }
            let reply = try await bridge.send(
                SetAssemblyCommand(assemblyId: identifier), expecting: Reply.self)
            assembly = identifier
            state = .loaded(atomCount: reply.atomCount)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Release the web view's memory without losing what is on screen.
    ///
    /// `WKWebView` is a separate process and the system will terminate it under
    /// pressure rather than asking. Clearing the structure ourselves gives back
    /// most of the memory and leaves the page alive, so recovery is one command
    /// rather than a reload; the alternative is a blank viewer and a user who
    /// does not know why.
    public func releaseUnderMemoryPressure() async {
        guard case .loaded = state else { return }
        try? await bridge.send(ClearCommand())
        state = .ready
        assemblies = []
        assembly = nil
        guardrailNotice =
            "The structure was released to free memory. Load it again to carry on."
    }

    /// Draw the interaction profile in 3D, and report how much of it landed.
    ///
    /// The return value is the point. This feature has been built and removed
    /// twice, and the second attempt drew **0 of 40** lines while every test
    /// passed, because the tests asserted the command had been dispatched. An
    /// overlay that draws nothing is pixel-for-pixel identical to one with
    /// nothing to draw, so the only way to know is to count.
    @discardableResult
    public func drawInteractions(
        _ lines: [DrawInteractionsCommand.Line]
    ) async throws -> OverlayResult {
        let result = try await bridge.send(
            DrawInteractionsCommand(lines: lines), expecting: OverlayResult.self)
        overlay = result
        return result
    }

    public func clearInteractions() async {
        try? await bridge.send(ClearInteractionsCommand())
        overlay = nil
    }

    /// What the last overlay attempt achieved, or `nil` if none was attempted.
    public private(set) var overlay: OverlayResult?

    public struct OverlayResult: Decodable, Sendable, Hashable {
        public let requested: Int
        public let drawn: Int
        /// Why the first few failures failed, verbatim from the viewer.
        public let unresolved: [String]

        /// Whether every line asked for was drawn.
        public var isComplete: Bool { drawn == requested }

        /// A sentence for the user, or `nil` when there is nothing to say.
        ///
        /// Silence when it all worked, and a specific count when it did not.
        /// "Some interactions could not be drawn" is the kind of message that
        /// trains people to ignore messages.
        public var shortfall: String? {
            guard requested > 0, drawn < requested else { return nil }
            let missing = requested - drawn
            return "\(missing) of \(requested) contacts could not be placed on the structure."
        }
    }

    /// Render the current view as a PNG at an arbitrary size.
    ///
    /// Returns the decoded bytes and the size the renderer actually produced,
    /// which is not necessarily the size requested: the helper clamps to its
    /// own bounds, and a caller that assumes otherwise writes a figure caption
    /// claiming a resolution the file does not have.
    ///
    /// - Throws: whatever the bridge throws, including the explicit error the
    ///   handler raises when this build has no screenshot helper. That is
    ///   deliberate: an export that silently returns nothing looks exactly like
    ///   one that rendered an empty scene.
    public func exportImage(
        width: Int, height: Int, transparent: Bool
    ) async throws -> ExportedImage {
        struct Payload: Decodable {
            let base64: String
            let width: Int
            let height: Int
        }
        let payload = try await bridge.send(
            ExportImageCommand(width: width, height: height, transparent: transparent),
            expecting: Payload.self)
        guard let data = Data(base64Encoded: payload.base64) else {
            throw ViewerBridgeError.decoding("the exported image was not valid base64")
        }
        return ExportedImage(data: data, width: payload.width, height: payload.height)
    }

    public struct ExportedImage: Sendable, Hashable {
        public let data: Data
        /// The size the renderer produced, read back rather than assumed.
        public let width: Int
        public let height: Int

        public init(data: Data, width: Int, height: Int) {
            self.data = data
            self.width = width
            self.height = height
        }

        /// The dimensions written in the PNG's own header.
        ///
        /// Read from the bytes rather than taken from the renderer's report,
        /// because those are two different claims and only one of them is in
        /// the file the user will send to a journal. A PNG's IHDR chunk starts
        /// at byte 16 with width then height, each a big-endian UInt32.
        public var declaredSize: (width: Int, height: Int)? {
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
            func word(at offset: Int) -> Int {
                let bytes = Array(data[data.startIndex + offset..<data.startIndex + offset + 4])
                return bytes.reduce(0) { $0 << 8 | Int($1) }
            }
            return (word(at: 16), word(at: 20))
        }
    }

    public func resetCamera() async {
        try? await bridge.send(ResetCameraCommand())
    }

    /// Shorthand so the call sites read as commands rather than as types.
    private typealias SetRepresentation = SetRepresentationCommand
}

#if canImport(UIKit)

/// The web view, wrapped.
public struct StructureViewerView: UIViewRepresentable {
    private let model: StructureViewerModel

    public init(model: StructureViewerModel) {
        self.model = model
    }

    public func makeUIView(context: Context) -> WKWebView {
        model.start()
        return model.bridge.webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {}
}

#endif
