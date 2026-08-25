//  ViewerBridge.swift
//  BoffinViewer
//
//  The Swift half of the bridge: one web view, one message handler, one entry
//  point in each direction.
//
//  Swift to JS goes through `callAsyncJavaScript` with the command as an
//  ARGUMENT, never as source. JS to Swift arrives at a single handler named
//  `boffin` carrying a tagged union. Two handlers would be two ways to say the
//  same thing, which is how a bridge acquires a dialect.

import BoffinCore
import Foundation
import WebKit

public enum ViewerBridgeError: Error, Sendable {
    case notLoaded
    case resourcesMissing(String)
    case javaScript(String)
    case decoding(String)
}

/// Everything the viewer needs from the bundle, in one place so a missing file
/// is one clear error rather than a blank web view.
public struct ViewerResources: Sendable {
    public let directory: URL
    public let page: URL

    /// Locate the vendored viewer inside a bundle.
    public init(bundle: Bundle) throws {
        guard
            let page = bundle.url(
                forResource: "boffin-viewer", withExtension: "html",
                subdirectory: "Web")
                ?? bundle.url(forResource: "boffin-viewer", withExtension: "html")
        else {
            throw ViewerBridgeError.resourcesMissing(
                "boffin-viewer.html is not in the bundle: the vendored Mol* build in "
                    + "Packages/BoffinViewer/Sources/BoffinViewer/Resources was not copied")
        }
        self.page = page
        self.directory = page.deletingLastPathComponent()

        for required in ["molstar.js", "molstar.css", "boffin-bridge.js"] {
            let file = directory.appending(path: required)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ViewerBridgeError.resourcesMissing(
                    "\(required) is missing from the viewer resources")
            }
        }
    }

    /// The package's own bundle, which is where the vendored build lives.
    public static func bundled() throws -> ViewerResources {
        try ViewerResources(bundle: .module)
    }
}

/// Runs the viewer and carries commands to it.
///
/// `@MainActor` rather than an actor of its own: `WKWebView` is main-actor
/// bound, and wrapping it in a second isolation domain would mean hopping to the
/// main actor inside every method anyway, with the added ceremony of pretending
/// otherwise.
@MainActor
public final class ViewerBridge: NSObject {

    public let webView: WKWebView
    private let resources: ViewerResources
    private var continuation: AsyncStream<ViewerEvent>.Continuation?
    private var isLoaded = false

    /// Events from the viewer: ready, loaded, picks, hovers, failures.
    public let events: AsyncStream<ViewerEvent>

    public init(resources: ViewerResources) {
        self.resources = resources

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if canImport(UIKit)
        // iOS only. The package also builds for macOS so its tests can run on
        // the host without a simulator, and `scrollView` and `isOpaque` are
        // UIKit properties that do not exist there.
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        #endif
        #if DEBUG
        // Safari Web Inspector, which is the only way to see what Mol* is doing.
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.isInspectable = true
        }
        #endif
        self.webView = webView

        var sink: AsyncStream<ViewerEvent>.Continuation?
        self.events = AsyncStream { sink = $0 }
        self.continuation = sink

        super.init()
        configuration.userContentController.add(self, name: "boffin")
        webView.navigationDelegate = self
    }

    /// Load the local page. Nothing else may be navigated to.
    public func start() {
        webView.loadFileURL(resources.page, allowingReadAccessTo: resources.directory)
    }

    /// Send a command and decode its reply.
    ///
    /// - Parameters:
    ///   - command: the command value.
    ///   - reply: the type the bridge returns for it.
    /// - Returns: the decoded reply.
    /// - Throws: ``ViewerBridgeError`` if the page is not loaded, the bridge
    ///   reported an error, or the reply does not decode.
    @discardableResult
    public func send<C: ViewerCommand, R: Decodable>(
        _ command: C, expecting reply: R.Type
    ) async throws -> R {
        guard isLoaded else { throw ViewerBridgeError.notLoaded }

        let envelope: [String: Any] = [
            "name": command.name,
            "payload": try Self.payload(of: command),
        ]

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                "return await window.boffinDispatch(envelope);",
                arguments: ["envelope": envelope],
                contentWorld: .page)
        } catch {
            throw ViewerBridgeError.javaScript(error.localizedDescription)
        }

        guard let dictionary = result as? [String: Any] else {
            throw ViewerBridgeError.decoding("the bridge returned \(String(describing: result))")
        }
        if let message = dictionary["error"] as? String {
            throw ViewerBridgeError.javaScript(message)
        }
        let payload = dictionary["result"] ?? [:]
        let data = try JSONSerialization.data(
            withJSONObject: payload is NSNull ? [:] : payload)
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw ViewerBridgeError.decoding(String(describing: error))
        }
    }

    /// Send a command whose reply carries nothing.
    public func send<C: ViewerCommand>(_ command: C) async throws {
        _ = try await send(command, expecting: Empty.self)
    }

    /// A reply with nothing in it, for commands that only act.
    public struct Empty: Decodable, Sendable {
        public init() {}
        public init(from decoder: any Decoder) throws {}
    }

    /// Encode a command to a JSON object.
    ///
    /// Through `JSONEncoder` and back rather than by hand: the command types own
    /// their own encoding, and a hand-written dictionary is a second definition
    /// that drifts.
    nonisolated static func payload<C: ViewerCommand>(of command: C) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ViewerBridgeError.decoding("\(C.self) did not encode to an object")
        }
        var payload = object
        payload.removeValue(forKey: "name")
        return payload
    }
}

extension ViewerBridge: WKScriptMessageHandler {
    public nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == "boffin",
            let body = message.body as? [String: Any],
            let event = ViewerEvent(message: body)
        else { return }
        Task { @MainActor in self.continuation?.yield(event) }
    }
}

extension ViewerBridge: WKNavigationDelegate {
    public nonisolated func webView(
        _ webView: WKWebView, didFinish navigation: WKNavigation!
    ) {
        Task { @MainActor in
            self.isLoaded = true
            self.continuation?.yield(.ready)
        }
    }

    /// Nothing but the local page may load.
    ///
    /// The vendored build has no CDN references, and this is the guarantee that
    /// a future version of it cannot quietly acquire one: hard rule 2 is that
    /// the app works in aeroplane mode, and a viewer that silently reaches for
    /// the network works everywhere except where it matters.
    public func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        (action.request.url?.isFileURL ?? false) ? .allow : .cancel
    }
}
