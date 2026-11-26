import ArtelCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Where the preview's HTML, CSS and JavaScript live: `Contents/Resources/DocsRenderer` in the app bundle
/// (copied by build-app.sh), or the repository's `Resources/DocsRenderer` + `build/vendor/docs-web` when run
/// from a SwiftPM build.
enum DocsRendererResources {
    static let bundled: URL? = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("DocsRenderer", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else { return nil }
        return dir
    }()

    /// Repository root, from this source file's location (Sources/Artel/Views/…).
    static let repository: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A renderer file by its path under `app/` (`renderer.js`, `vendor/mermaid.min.js`).
    static func file(_ path: String) -> URL? {
        if let bundled { return contained(path, in: bundled) }
        if path.hasPrefix("vendor/") {
            return contained(String(path.dropFirst("vendor/".count)), in: repository.appendingPathComponent("build/vendor/docs-web"))
        }
        return contained(path, in: repository.appendingPathComponent("Resources/DocsRenderer"))
    }

    static var isAvailable: Bool { file("vendor/markdown-it.min.js").map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// `path` inside `dir`, refusing anything that escapes it.
    static func contained(_ path: String, in dir: URL) -> URL? {
        let url = dir.appendingPathComponent(path).standardizedFileURL
        return url.path.hasPrefix(dir.standardizedFileURL.path + "/") ? url : nil
    }
}

/// Serves `artel-res://local/app/…` (the renderer) and `artel-res://local/root/…` (files of the shown project,
/// for images and embedded diagrams). One origin for both, so `fetch` works without CORS.
final class ArtelResourceHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "artel-res"
    /// Files under `root/` are looked up here; nil serves nothing.
    var root: URL?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = (url.path.removingPercentEncoding ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var file: URL?
        if path.hasPrefix("app/") {
            file = DocsRendererResources.file(String(path.dropFirst(4)))
        } else if path == "ext/excalidraw.js" {
            file = MainActor.assumeIsolated { ExcalidrawAddon.shared.isInstalled } ? ExcalidrawAddon.file : nil
        } else if path.hasPrefix("root/"), let root {
            file = DocsRendererResources.contained(String(path.dropFirst(5)), in: root)
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let type = file.pathExtension == "js" ? "text/javascript"
            : UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? (file.pathExtension == "excalidraw" ? "application/json" : "application/octet-stream")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)",
                                                      "Cache-Control": "no-cache"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A selection in the preview, with the source lines of the blocks it covers (0-based, end exclusive).
struct PreviewSelection: Equatable {
    var text: String
    var firstLine: Int?
    var lastLine: Int?
}

/// What to render. Equal options are not re-rendered.
struct MarkdownRenderOptions: Equatable {
    var markdown: String
    /// File line of the markdown's first line (the frontmatter that was cut off).
    var lineOffset = 0
    /// Shown as the page heading when the markdown has no `# heading` (frontmatter `title`).
    var title: String?
    var mdx = false
    var highlight: String?
    /// Heading id to scroll to (`page.md#anchor`).
    var anchor: String?
    var emptyText = "Пусто"
    /// Folder of the document, relative to the served root: relative images and links resolve against it.
    var baseDir = ""
}

/// Rendered markdown in a WKWebView (Resources/DocsRenderer): Docusaurus admonitions, Mermaid, KaTeX,
/// Excalidraw, highlighted code. Links go to `onLink` as written (`docs/a.md`, `https://…`, `artel-doc:…`).
struct MarkdownWebView: NSViewRepresentable {
    var options: MarkdownRenderOptions
    /// Served under `artel-res://local/root/`; nil = no local images.
    var root: URL?
    /// Identity of the shown document: a new one scrolls to the top, the same one keeps the position.
    var documentID: String
    var onLink: (String) -> Void
    var onSelection: ((PreviewSelection?) -> Void)?
    /// Adds "ask the agent" to the context menu of a selection.
    var askAgent: ((PreviewSelection) -> Void)?

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownWebView
        let handler = ArtelResourceHandler()
        var ready = false
        var rendered: (MarkdownRenderOptions, String)?
        var pending: (MarkdownRenderOptions, String)?
        var selection: PreviewSelection?
        var fontsKey = ""

        init(_ parent: MarkdownWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let (options, id) = pending ?? rendered { render(options, id: id, in: message.webView) }
            case "link":
                if let href = body["href"] as? String { parent.onLink(href) }
            case "selection":
                let text = body["text"] as? String ?? ""
                selection = text.isEmpty ? nil
                    : PreviewSelection(text: text, firstLine: (body["firstLine"] as? NSNumber)?.intValue,
                                       lastLine: (body["lastLine"] as? NSNumber)?.intValue)
                parent.onSelection?(selection)
            case "log":
                DebugScript.log("preview: \(body["text"] as? String ?? "")")
            default: break
            }
        }

        func render(_ options: MarkdownRenderOptions, id: String, in webView: WKWebView?) {
            guard let webView else { return }
            guard ready else { pending = (options, id); return }
            let fonts = AppFonts.shared.settings
            let sameDocument = rendered?.1 == id
            let payload: [String: Any] = [
                "markdown": options.markdown,
                "lineOffset": options.lineOffset,
                "title": options.title as Any,
                "mdx": options.mdx,
                "highlight": options.highlight as Any,
                "anchor": options.anchor as Any,
                "emptyText": options.emptyText,
                "base": "artel-res://local/root/" + (options.baseDir.isEmpty ? "" : Self.encodePath(options.baseDir) + "/"),
                "font": fonts.preview.family.map { "\"\($0)\", -apple-system, sans-serif" } ?? "-apple-system, BlinkMacSystemFont, sans-serif",
                "fontSize": fonts.preview.size,
                "codeFont": fonts.code.family.map { "\"\($0)\", ui-monospace, Menlo, monospace" } ?? "ui-monospace, \"SF Mono\", Menlo, monospace",
                "keepScroll": sameDocument && options.highlight == nil && options.anchor == nil,
                // Excalidraw's own exporter, when downloaded (ExcalidrawAddon); else the built-in renderer.
                "excalidrawModule": ExcalidrawAddon.shared.isInstalled ? "artel-res://local/ext/excalidraw.js" : NSNull(),
            ]
            pending = nil
            rendered = (options, id)
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.artel && window.artel.render(\(json))")
        }

        static func encodePath(_ path: String) -> String {
            path.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
            }.joined(separator: "/")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Only the renderer page itself loads in the view; everything else is a link to hand over.
            let scheme = action.request.url?.scheme
            if (scheme == ArtelResourceHandler.scheme || scheme == "about") && action.navigationType == .other {
                decisionHandler(.allow)
            } else {
                if let url = action.request.url { parent.onLink(url.absoluteString) }
                decisionHandler(.cancel)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            pending = rendered
            webView.load(URLRequest(url: MarkdownWebView.pageURL))
        }
    }

    /// The web view with the "ask the agent" item in the context menu of a selection.
    final class PreviewWebView: WKWebView {
        weak var coordinator: Coordinator?

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            // Reloading would only show the bare renderer page.
            menu.items.removeAll { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }
            guard let coordinator, coordinator.parent.askAgent != nil, coordinator.selection != nil else { return }
            let item = NSMenuItem(title: "Попросить агента изменить фрагмент…", action: #selector(askAgent(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        @objc private func askAgent(_ sender: Any?) {
            guard let coordinator, let selection = coordinator.selection else { return }
            coordinator.parent.askAgent?(selection)
        }
    }

    static let pageURL = URL(string: "artel-res://local/app/index.html")!

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 160))
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: ArtelResourceHandler.scheme)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "artel")
        config.websiteDataStore = .nonPersistent()
        let web = PreviewWebView(frame: .zero, configuration: config)
        web.coordinator = context.coordinator
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = true
        context.coordinator.handler.root = root
        if DocsRendererResources.isAvailable {
            web.load(URLRequest(url: Self.pageURL))
        } else {
            web.loadHTMLString("<p style='font:13px -apple-system;color:gray;padding:16px'>Просмотр недоступен: нет файлов рендерера. Запустите scripts/fetch-docs-web.sh и пересоберите приложение.</p>", baseURL: nil)
        }
        context.coordinator.render(options, id: documentID, in: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.handler.root = root
        let fonts = AppFonts.shared.settings
        let fontsKey = "\(fonts.preview.family ?? "")\(fonts.preview.size)\(fonts.code.family ?? "")|\(ExcalidrawAddon.shared.revision)"
        let last = c.pending ?? c.rendered
        if last?.0 != options || last?.1 != documentID || c.fontsKey != fontsKey {
            c.fontsKey = fontsKey
            c.render(options, id: documentID, in: web)
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "artel")
    }
}

/// WKUserContentController retains its handlers: a weak hop avoids a cycle with the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
