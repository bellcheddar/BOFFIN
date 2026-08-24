//  ViewerCommand.swift
//  BoffinViewer
//
//  The typed command envelope for the Swift to JavaScript bridge.
//
//  Hard rule: never string-interpolate into JavaScript. All Mol* traffic goes
//  through this envelope, JSON-encoded, via `callAsyncJavaScript`. Ad-hoc
//  `evaluateJavaScript` string building scattered through view code is the
//  failure mode this module exists to prevent.
//
//  A future native Metal renderer implements the same protocol, so the SwiftUI
//  layer above does not change when the renderer does.
//
//  Phase 0 establishes the module boundary and the protocol. Phase 7 vendors
//  the Mol* UMD build into Resources/ and implements the bridge.

import BoffinCore
import BoffinStructure

/// A command sent from Swift to the viewer.
public protocol ViewerCommand: Encodable, Sendable {
    var name: String { get }
}

/// An event sent from the viewer back to Swift: picks, hovers, load completion.
public enum ViewerEvent: Sendable, Hashable {
    case loaded(atomCount: Int)
    case picked(chainID: String, authorNumber: Int)
    case hovered(chainID: String, authorNumber: Int)
    case failed(message: String)
}
