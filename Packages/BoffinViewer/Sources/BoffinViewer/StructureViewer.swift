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
