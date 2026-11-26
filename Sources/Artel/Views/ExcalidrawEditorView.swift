import AppKit
import SwiftUI
import WebKit

/// Excalidraw's own editor for one `.excalidraw` file (Resources/DocsRenderer/excalidraw-editor.html, needs the
/// Excalidraw download). The scene is loaded once per `documentID`; every change of the drawing comes back through
/// `onChange` as the file's new JSON (the caller keeps it as a draft and saves explicitly).
struct ExcalidrawEditorView: NSViewRepresentable {
    var json: String
    var documentID: String
    var onChange: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: ExcalidrawEditorView
        let handler = ArtelResourceHandler()
        var ready = false
        var loadedID: String?
        var theme = "light"

        init(_ parent: ExcalidrawEditorView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                load(in: message.webView)
            case "change":
                if let json = body["json"] as? String { parent.onChange(json) }
            case "log":
                DebugScript.log("excalidraw editor: \(body["text"] as? String ?? "")")
            default: break
            }
        }

        func load(in webView: WKWebView?) {
            guard ready, let webView else { return }
            loadedID = parent.documentID
            let args = [parent.json, theme]
            guard let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.artelEditor && window.artelEditor.load(...\(json))")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.request.url?.scheme == ArtelResourceHandler.scheme && action.navigationType == .other {
                decisionHandler(.allow)
            } else {
                // Links inside drawings open in the browser, never in the editor's page.
                if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
    }

    static let pageURL = URL(string: "artel-res://local/app/excalidraw-editor.html")!

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: ArtelResourceHandler.scheme)
        config.userContentController.add(EditorMessageHandler(context.coordinator), name: "artel")
        config.websiteDataStore = .nonPersistent()
        let web = EditorWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.theme = colorScheme == .dark ? "dark" : "light"
        web.load(URLRequest(url: Self.pageURL))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let theme = colorScheme == .dark ? "dark" : "light"
        if theme != c.theme {
            c.theme = theme
            web.evaluateJavaScript("window.artelEditor && window.artelEditor.setTheme('\(theme)')")
        }
        if c.ready && c.loadedID != documentID { c.load(in: web) }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "artel")
    }
}

/// Gives Excalidraw its own ⌘-shortcuts. The app menu would take Undo, Redo, Select All and friends before the page
/// sees the keys, so while the drawing has the keyboard a local event monitor hands those presses to the page
/// directly (Excalidraw listens on the document). Edit-menu commands chosen with the mouse land here as
/// `undo:` / `redo:` / `selectAll:` and do the same. Copy, cut and paste stay with the menu: WebKit turns them into
/// the clipboard events Excalidraw listens to.
private final class EditorWebView: WKWebView, NSMenuItemValidation {
    /// ⌘-keys Excalidraw handles itself (undo/redo, select all, duplicate, group, link, lock, layers, zoom…).
    static let pageShortcuts: Set<String> = ["z", "y", "a", "d", "g", "k", "l", "[", "]", "'", "/", "0", "-", "=", "+"]
    private var monitor: Any?

    /// The drawing takes the keyboard (shortcuts, typing into text elements) as soon as it is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handles(event) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.shortcut(event.charactersIgnoringModifiers?.lowercased() ?? "", shift: flags.contains(.shift),
                          option: flags.contains(.option))
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func handles(_ event: NSEvent) -> Bool {
        guard event.window === window, let window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased(), Self.pageShortcuts.contains(key),
              let responder = window.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    @objc func undo(_ sender: Any?) { shortcut("z") }
    @objc func redo(_ sender: Any?) { shortcut("z", shift: true) }
    override func selectAll(_ sender: Any?) { shortcut("a") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if [#selector(undo(_:)), #selector(redo(_:)), #selector(selectAll(_:))].contains(item.action) { return true }
        return (self as NSResponder).responds(to: item.action)
    }

    /// A ⌘-key press as Excalidraw's keyboard handler expects it.
    private func shortcut(_ key: String, shift: Bool = false, option: Bool = false) {
        guard let first = key.unicodeScalars.first else { return }
        let code = CharacterSet.letters.contains(first) ? "Key" + key.uppercased() : ""
        let payload: [String: Any] = ["key": shift ? key.uppercased() : key, "code": code, "metaKey": true,
                                      "shiftKey": shift, "altKey": option, "bubbles": true, "cancelable": true]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8)
        else { return }
        evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', \(json)))")
    }
}

/// WKUserContentController retains its handlers: a weak hop avoids a cycle with the coordinator.
private final class EditorMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
