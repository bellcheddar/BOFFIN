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
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
