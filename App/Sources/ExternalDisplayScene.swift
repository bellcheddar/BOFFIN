//  ExternalDisplayScene.swift
//  BOFFIN
//
//  The wiring that puts the structure on a projector.
//
//  Only the wiring. The decision about WHICH connecting scene is a projector
//  lives in `BoffinViewer.ExternalDisplay`, because the app's test bundle is
//  configured as a UI-test target and nothing here can be reached by a unit
//  test. What is left in this file is code that cannot be tested anywhere
//  without the hardware, and it is kept as small as that argument requires.
//
//  Not verified on a display. The simulator can attach one from its I/O menu
//  but not from the command line, and no projector was available, so what is
//  claimed here is that the routing is correct and the presenter view builds --
//  not that it has been seen.

import BoffinCore
import BoffinStructure
import BoffinUI
import BoffinViewer
import SwiftUI
import UIKit

/// The window that appears on the projector.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: PresenterView(bridge: PresentationBridge.shared))
        window.isHidden = false
        self.window = window
        PresentationBridge.shared.attach()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        PresentationBridge.shared.detach()
        window = nil
    }
}

final class BoffinAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: session.role)
        // The raw value is passed straight through so the package's test is
        // testing the same string UIKit will hand over, rather than a copy of
        // it that can drift.
        if ExternalDisplay.isPresenterScene(role: session.role.rawValue) {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

/// What the room sees.
///
/// Deliberately not the app's interface mirrored. A projector showing tab bars
/// and controls is showing the presenter's tools to the audience; what the
/// audience wants is the structure, large, with the scene's name and notes
/// where they can be read from the back.
struct PresenterView: View {
    @Bindable var bridge: PresentationBridge
    // Built on appear rather than at initialisation: the viewer's initialiser
    // throws, and a projector that fails to start its renderer must show that
    // it failed rather than take the whole external scene down.
    @State private var viewer: StructureViewerModel?
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()

            if let viewer {
                StructureViewerView(model: viewer)
                    .ignoresSafeArea()
            } else if let failure {
                // Shown on the projector, because the presenter is looking at
                // the room and a blank screen behind them says nothing.
                Text(failure)
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .padding(Spacing.l)
            }

            if let scene = bridge.scene {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(scene.name)
                        .font(.system(size: 44, weight: .semibold))
                    if !scene.notes.isEmpty {
                        Text(scene.notes)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.l)
                // A caption over a dark render needs its own ground: a white
                // label on a pale helix is unreadable from the back of a room.
                .background(.ultraThinMaterial, in: .rect(cornerRadius: Spacing.m))
                .padding(Spacing.l)
            }
        }
        .task {
            guard viewer == nil else { return }
            do {
                let model = try StructureViewerModel()
                model.start()
                viewer = model
            } catch {
                failure = "The structure viewer could not start on this display."
            }
        }
        .task(id: bridge.structure) {
            guard let viewer, let data = bridge.structure else { return }
            await viewer.load(data, format: bridge.format)
        }
        .task(id: bridge.scene?.id) {
            guard let viewer, let scene = bridge.scene else { return }
            await viewer.apply(scene)
        }
    }
}
