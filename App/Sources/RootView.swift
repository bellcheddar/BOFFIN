//  RootView.swift
//  BOFFIN
//
//  The five tabs of the build plan, and the one-time welcome sheet.

import BoffinCore
import BoffinUI
import SwiftUI

struct RootView: View {
    @State private var store = SequenceStore()
    @State private var openError: UserFacingError?

    /// Whether the welcome sheet has been seen.
    ///
    /// Stored rather than shown every launch, and stored as "has seen" rather
    /// than "is first run" so that a future version can reset it by bumping the
    /// key when there is something new worth saying.
    @AppStorage("boffin.onboarding.seen.v1") private var hasSeenOnboarding = false
    @State private var isShowingOnboarding = false

    /// Launch as though the welcome sheet had already been seen.
    ///
    /// The UI tests each drive a specific screen and a sheet over the tabs on a
    /// fresh install would fail all fourteen of them for a reason that has
    /// nothing to do with what they test. This is the standard way out, and it
    /// carries the standard risk: a switch that suppresses a feature can
    /// suppress it everywhere and look like the feature was never built. So
    /// `OnboardingUITests` deliberately launches WITHOUT the argument and
    /// asserts the sheet appears, which is the test the flag cannot pass by
    /// disabling anything.
    private static var suppressOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-boffin.skip-onboarding")
    }

    var body: some View {
        TabView {
            Tab("Order", systemImage: "waveform.path.ecg") {
                OrderTabView(store: store)
            }
            Tab("Fitness", systemImage: "square.grid.3x3") {
                FitnessTabView(store: store)
            }
            Tab("Family", systemImage: "point.3.connected.trianglepath.dotted") {
                FamilyTabView(store: store)
            }
            Tab("Boundary", systemImage: "scissors") {
                BoundaryTabView(store: store)
            }
            Tab("Structure", systemImage: "atom") {
                StructureTabView(store: store)
            }
        }
        // A FASTA shared from Mail, Files or AirDrop. The plist half of this is
        // in Info.plist and is the half that is invisible when it is missing:
        // without CFBundleDocumentTypes the share sheet never offers BOFFIN and
        // this closure is never called, which reads as a bug in the handler.
        .onOpenURL { url in
            do {
                let text = try OpenedDocument.read(url)
                store.load(text: text, fileName: url.lastPathComponent)
                openError = nil
            } catch let failure as OpenedDocument.Failure {
                // Already written for a person: it names the file and what was
                // wrong with it, so it is not re-classified into something
                // vaguer.
                openError = UserFacingError(
                    summary: failure.message, detail: String(describing: failure))
            } catch {
                openError = UserFacingError(error, whileDoing: "opening that file")
            }
        }
        .alert(
            "Could not open that file", isPresented: openAlert,
            actions: { Button("OK") { openError = nil } },
            message: { Text(openError?.summary ?? "") }
        )
        // Shown once. Not blocking: it is a sheet over a working app rather
        // than a gate in front of one, so a returning user who has cleared
        // their storage loses a swipe rather than their place.
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView(store: store)
        }
        .task {
            guard !Self.suppressOnboarding else { return }
            guard !hasSeenOnboarding else { return }
            hasSeenOnboarding = true
            isShowingOnboarding = true
        }
        // Separate from the onboarding task deliberately: that one returns
        // early on every launch after the first, and warming the backbone is
        // most valuable exactly then.
        .task { await store.warmUpModel() }
        // The engine is now held for the app's lifetime, so its embedding
        // cache is worth giving back when the system asks. The model stays
        // loaded: reloading it would repay the cost the warm-up just avoided.
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)
        ) { _ in
            Task { await store.releaseEmbeddingCache() }
        }
    }

    private var openAlert: Binding<Bool> {
        Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })
    }
}

#Preview {
    RootView()
}
