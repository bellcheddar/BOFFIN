//  ExternalDisplay.swift
//  BoffinViewer
//
//  A presenter view on the device and the structure on the projector.
//
//  Two pieces live here rather than in the app target, for the reason
//  `SceneDeckModel` gives at the top of its own file: the app's unit-test
//  bundle is configured as a UI-test target, so nothing in the app can be
//  reached by `swift test`. The scene ROUTING is the part that can silently be
//  wrong -- a mistake there means the app either never opens a window on the
//  projector or opens its whole interface on it -- and neither failure is
//  visible without the hardware. So the decision is a pure function over the
//  session role, tested here, and the app target keeps only the wiring that
//  cannot be tested anywhere.

import BoffinStructure
import Foundation
import Observation

public enum ExternalDisplay {

    /// UIKit's raw value for a non-interactive external-display scene.
    ///
    /// Matched as a string rather than against `UISceneSession.Role` so this
    /// stays free of UIKit and runs under `swift test` on macOS. The app
    /// target passes `session.role.rawValue` straight through, so the two
    /// cannot drift without the test noticing.
    public static let presenterRole = "UIWindowSceneSessionRoleExternalDisplayNonInteractive"

    /// The role UIKit gives the device's own window.
    public static let deviceRole = "UIWindowSceneSessionRoleApplication"

    /// Whether a connecting scene should show the presenter output.
    ///
    /// Deliberately not "anything that is not the application role". A scene
    /// role that is neither of these -- CarPlay, or a role added by a future
    /// release -- must fall through to the normal interface rather than be
    /// handed a projector view, because guessing wrong there puts a structure
    /// on a dashboard.
    public static func isPresenterScene(role: String) -> Bool {
        role == presenterRole
    }
}

/// What the projector should be showing.
///
/// The device's window and the external one are separate scenes with separate
/// view hierarchies, so they cannot share `@State`. This is the one object both
/// read, and it holds the structure's bytes rather than a reference to the
/// on-device viewer: the external window runs its own Mol\* instance, and
/// asking one WebView to render into another is not a thing that exists.
@MainActor
@Observable
public final class PresentationBridge {

    public static let shared = PresentationBridge()

    public init() {}

    /// The structure to show, and how it was loaded.
    public private(set) var structure: Data?
    public private(set) var format: LoadStructureCommand.StructureFormat = .binaryCIF
    /// The scene being presented, or `nil` when the deck is not presenting.
    public private(set) var scene: ViewerScene?
    /// What the structure is called, for the caption.
    public private(set) var title: String = ""

    /// Whether a projector is attached and being driven.
    ///
    /// Set by the external scene itself on connect and clear on disconnect, so
    /// the device side can offer presenter controls only when there is
    /// somewhere to present. Inferring it from `scene != nil` would be wrong in
    /// both directions: a deck can be presented with no projector, and a
    /// projector can be attached with no deck.
    public private(set) var isAttached = false

    public func present(_ scene: ViewerScene?) { self.scene = scene }

    public func load(
        _ data: Data, format: LoadStructureCommand.StructureFormat,
        title: String
    ) {
        self.structure = data
        self.format = format
        self.title = title
    }

    public func attach() { isAttached = true }

    public func detach() {
        isAttached = false
        // The structure is kept. A projector unplugged mid-talk and plugged
        // back in should resume, not come back to an empty window.
    }
}
