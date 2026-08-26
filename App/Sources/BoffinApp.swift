//  BoffinApp.swift
//  BOFFIN
//
//  Entry point, routing and dependency injection only. All behaviour lives in
//  the packages under Packages/: if logic starts accumulating here, it belongs
//  in a module instead.

import BoffinCharts
import BoffinCore
import BoffinData
import BoffinML
import BoffinStructure
import BoffinUI
import BoffinViewer
import SwiftUI

@main
struct BoffinApp: App {
    /// Present only to route external-display scenes.
    ///
    /// SwiftUI's `App` gives no hook for a scene it does not create itself, and
    /// a projector arrives as a `UIWindowScene` UIKit connects. The adaptor is
    /// the supported way to answer that connection; see
    /// `ExternalDisplayScene.swift` for what it answers with.
    @UIApplicationDelegateAdaptor(BoffinAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
