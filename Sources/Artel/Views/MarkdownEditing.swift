import ArtelCore
import AppKit
import MarkdownUI
import SwiftUI

/// What the page editor can complete after `](` and `[[`: the documentation pages, linked relative to `page`.
struct LinkCompletionSource {
    var page: String
    var pages: [(path: String, title: String)]
}

/// Markdown text editor (NSTextView) with light syntax highlighting.
/// Dropped files/URLs become references at the drop point via `referencesForDrop`; a pasted image goes through
/// `pasteImage`. Esc and ⌘⏎ call `onExit` (leave the editor).
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Set by the parent to insert text at the cursor (toolbar buttons).
    var insertion: Binding<String?> = .constant(nil)
    var referencesForDrop: (([URL]) -> [String])?
    /// Saves pasted image data (PNG) and returns the markdown to insert; nil = paste as usual.
    var pasteImage: ((Data) -> String?)?
    var completion: LinkCompletionSource?
    var onExit: (() -> Void)?
    /// The selected range (UTF-16) after every selection change.
    var onSelection: ((NSRange) -> Void)?
    /// Editor font; code spans use the code font's family at the editor's size.
    var font: FontChoice = AppFonts.shared.settings.editor
    var codeFont: FontChoice = AppFonts.shared.settings.code

    final class EditorView: NSTextView {
        var referencesForDrop: (([URL]) -> [String])?
        var pasteImage: ((Data) -> String?)?
        var onExit: (() -> Void)?
        let completionPopup = CompletionPopup()

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            super.readablePasteboardTypes + [.fileURL, .URL]
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
            guard !urls.isEmpty, let refs = referencesForDrop?(urls), !refs.isEmpty else {
                return super.performDragOperation(sender)
            }
            let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
            let at = NSRange(location: min(index, (string as NSString).length), length: 0)
            window?.makeFirstResponder(self)
            insertText(refs.joined(separator: "\n"), replacementRange: at)
            return true
        }

        override func paste(_ sender: Any?) {
            let pb = NSPasteboard.general
            if let pasteImage, pb.string(forType: .string) == nil, let data = Self.pngData(pb), let markdown = pasteImage(data) {
                insertText(markdown, replacementRange: selectedRange())
                return
            }
            if let referencesForDrop, pb.string(forType: .string) == nil,
               let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                let refs = referencesForDrop(urls)
                if !refs.isEmpty { insertText(refs.joined(separator: "\n"), replacementRange: selectedRange()); return }
            }
            super.paste(sender)
        }

        static func pngData(_ pb: NSPasteboard) -> Data? {
            if let png = pb.data(forType: .png) { return png }
            guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }

        /// While the completion list is open the arrows move through it, ⏎/⇥ insert the item and Esc closes it.
        override func doCommand(by selector: Selector) {
            if completionPopup.isVisible {
                switch selector {
                case #selector(moveUp(_:)): completionPopup.move(-1); return
                case #selector(moveDown(_:)): completionPopup.move(1); return
                case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                    completionPopup.accept(); return
                case #selector(cancelOperation(_:)): completionPopup.hide(); return
                default: break
                }
            }
            super.doCommand(by: selector)
        }

        /// Esc leaves the editor. Without `onExit` it does nothing: NSTextView would open the system word completion.
        override func cancelOperation(_ sender: Any?) {
            if completionPopup.isVisible { completionPopup.hide() } else { onExit?() }
        }

        /// ⌘⏎ leaves the editor; it beats the menu's ⌘⏎ while the editor has the keyboard.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let onExit, flags == .command, event.keyCode == 36 || event.keyCode == 76, window?.firstResponder === self {
                onExit()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func resignFirstResponder() -> Bool {
            completionPopup.hide()
            return super.resignFirstResponder()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { completionPopup.hide() }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Shows `items` under the text at `range`, or hides the list when there are none.
        func showCompletions(_ items: [DocsCompletion.Candidate], below range: NSRange) {
            guard !items.isEmpty, let window else { completionPopup.hide(); return }
            let anchor = firstRect(forCharacterRange: range, actualRange: nil)
            completionPopup.show(items, under: anchor, in: window)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var isUpdating = false
        var appliedFonts: (FontChoice, FontChoice)?
        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? EditorView else { return }
            let s = tv.string
            // Restyling the storage would wipe the input method's marked-text underline; restyle once it is committed.
            if !tv.hasMarkedText() { MarkdownHighlighter.apply(to: tv, font: parent.font, code: parent.codeFont) }
            if parent.text != s { parent.text = s }
            updateCompletions(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? EditorView else { return }
            if tv.completionPopup.isVisible, DocsCompletion.query(in: tv.string, caret: tv.selectedRange().location) == nil {
                tv.completionPopup.hide()
            }
            guard let onSelection = parent.onSelection else { return }
            let range = tv.selectedRange()
            DispatchQueue.main.async { onSelection(range) }
        }

        private func updateCompletions(_ tv: EditorView) {
            guard let source = parent.completion, tv.selectedRange().length == 0,
                  let query = DocsCompletion.query(in: tv.string, caret: tv.selectedRange().location) else {
                tv.completionPopup.hide()
                return
            }
            tv.completionPopup.onPick = { [weak tv] candidate in
                guard let tv, let query = DocsCompletion.query(in: tv.string, caret: tv.selectedRange().location) else { return }
                tv.completionPopup.hide()
                tv.insertText(candidate.insertion, replacementRange: query.range)
            }
            tv.showCompletions(DocsCompletion.candidates(query, pages: source.pages, fromPage: source.page), below: query.range)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The editor takes whatever space it is offered, so a split view's column never follows the text's line wrapping.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 160))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        let tv = scroll.documentView as! EditorView
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = MarkdownHighlighter.baseFont(font)
        tv.textColor = .textColor
        tv.insertionPointColor = .textColor
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 10
        tv.delegate = context.coordinator
        configure(tv)
        tv.string = text
        MarkdownHighlighter.apply(to: tv, font: font, code: codeFont)
        context.coordinator.appliedFonts = (font, codeFont)
        if onExit != nil {
            // A page opened for editing takes the keyboard right away.
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    private func configure(_ tv: EditorView) {
        tv.referencesForDrop = referencesForDrop
        tv.pasteImage = pasteImage
        tv.onExit = onExit
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? EditorView else { return }
        context.coordinator.parent = self
        configure(tv)
        // Only replace on external changes, so typing doesn't lose the caret.
        if tv.string != text && !tv.hasMarkedText() {
            let selection = tv.selectedRange()
            context.coordinator.isUpdating = true
            tv.string = text
            context.coordinator.isUpdating = false
            MarkdownHighlighter.apply(to: tv, font: font, code: codeFont)
            context.coordinator.appliedFonts = (font, codeFont)
            if selection.upperBound <= (text as NSString).length { tv.setSelectedRange(selection) }
        }
        if let applied = context.coordinator.appliedFonts, applied != (font, codeFont) {
            tv.font = MarkdownHighlighter.baseFont(font)
            MarkdownHighlighter.apply(to: tv, font: font, code: codeFont)
            context.coordinator.appliedFonts = (font, codeFont)
        }
        if let value = insertion.wrappedValue, !value.isEmpty {
            tv.insertText(value, replacementRange: tv.selectedRange())
            DispatchQueue.main.async { insertion.wrappedValue = nil }
        }
    }
}

/// The link completion list: a borderless child panel under the caret. It never takes the keyboard; the editor
/// forwards the arrows, ⏎/⇥ and Esc to it (`EditorView.doCommand`).
@MainActor final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var items: [DocsCompletion.Candidate] = []
    var onPick: ((DocsCompletion.Candidate) -> Void)?
    private lazy var table: NSTableView = {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        return table
    }()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
        panel.contentView = effect
        return panel
    }()

    var isVisible: Bool { panel.isVisible }

    /// `anchor` is the completed text's rect in screen coordinates.
    func show(_ items: [DocsCompletion.Candidate], under anchor: NSRect, in window: NSWindow) {
        let previous = table.selectedRow >= 0 && table.selectedRow < self.items.count ? self.items[table.selectedRow] : nil
        self.items = items
        table.reloadData()
        let row = previous.flatMap { items.firstIndex(of: $0) } ?? 0
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let height = CGFloat(min(items.count, 8)) * table.rowHeight + 8
        var frame = NSRect(x: anchor.minX, y: anchor.minY - height - 4, width: 380, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = anchor.maxY + 4 }
            frame.origin.x = min(frame.minX, screen.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func accept() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { hide(); return }
        onPick?(items[row])
    }

    @objc private func clicked() {
        if table.clickedRow >= 0 { table.selectRowIndexes([table.clickedRow], byExtendingSelection: false); accept() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = items[row]
        let title = NSTextField(labelWithString: candidate.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: candidate.path)
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, path])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return stack
    }
}

/// Regex-based styling for markdown source: headings, emphasis, code, links and `@path` references.
/// Task texts and docs are prose: the system font, with monospace only for code and `@path` references.
enum MarkdownHighlighter {
    static func baseFont(_ font: FontChoice) -> NSFont { font.nsFont(monospaced: false) }
    static func codeFont(_ code: FontChoice, editor: FontChoice) -> NSFont {
        FontChoice(family: code.family, size: editor.size - 0.5).nsFont(monospaced: true)
    }

    nonisolated(unsafe) static let rules: [(NSRegularExpression, Style)] = ([
        (#"(?m)^#{1,6} .*$"#, .heading),
        (#"\*\*[^*\n]+\*\*"#, .bold),
        (#"`[^`\n]+`"#, .code),
        (#"(?m)^\s*([-*+]|\d+[.)]) "#, .marker),
        (#"(?m)^>.*$"#, .quote),
        (#"\[[^\]\n]*\]\([^)\n]*\)"#, .link),
        (#"(?<![\w/@.])@[\w./-]+"#, .reference),
        (#"https?://[^\s)]+"#, .link),
        (#"(?m)^- \[[ xX]\]"#, .marker),
        (#"(?s)<!--.*?-->"#, .comment),
        (#"(?ms)^```.*?^```\s*$"#, .codeBlock),
    ] as [(String, Style)]).map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    enum Style { case heading, bold, code, marker, quote, link, reference, comment, codeBlock }

    @MainActor static func apply(to tv: NSTextView, font: FontChoice, code codeChoice: FontChoice) {
        guard let storage = tv.textStorage else { return }
        let text = storage.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }
        let base = baseFont(font)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let code = codeFont(codeChoice, editor: font)
        let heading = NSFontManager.shared.convert(
            FontChoice(family: font.family, size: font.size + 2).nsFont(monospaced: false), toHaveTrait: .boldFontMask)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes([.font: base, .foregroundColor: NSColor.textColor], range: full)
        tv.typingAttributes = [.font: base, .foregroundColor: NSColor.textColor]
        for (re, style) in rules {
            for m in re.matches(in: text, range: full) {
                let r = m.range
                switch style {
                case .heading:
                    storage.addAttributes([.font: heading,
                                      .foregroundColor: NSColor.labelColor], range: r)
                case .bold: storage.addAttributes([.font: bold], range: r)
                case .code: storage.addAttributes([.font: code, .foregroundColor: NSColor.systemPink], range: r)
                case .marker: storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: r)
                case .quote: storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: r)
                case .link: storage.addAttributes([.foregroundColor: NSColor.linkColor], range: r)
                case .reference: storage.addAttributes([.font: code, .foregroundColor: NSColor.linkColor], range: r)
                case .comment: storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: r)
                case .codeBlock:
                    storage.addAttributes([.font: code, .foregroundColor: NSColor.systemPink,
                                      .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08)], range: r)
                }
            }
        }
    }
}

/// Rendered markdown (MarkdownUI). `@path` references and relative links become `artel-doc:` links,
/// handled by the `openURL` action of the surrounding view.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        let fonts = AppFonts.shared.settings
        Markdown(Self.linkImports(text))
            .markdownTheme(.gitHub.text {
                BackgroundColor(nil)
                if let family = fonts.preview.family { FontFamily(.custom(family)) }
                FontSize(fonts.preview.size)
            })
            .markdownTextStyle(\.code) {
                if let family = fonts.code.family { FontFamily(.custom(family)) } else { FontFamilyVariant(.monospaced) }
                FontSize(.em(0.85))
                BackgroundColor(Color.secondary.opacity(0.15))
            }
            .textSelection(.enabled)
    }

    /// `@docs/arch.md` → `[@docs/arch.md](artel-doc:docs/arch.md)`; relative markdown links → artel-doc: too.
    static func linkImports(_ s: String) -> String {
        var out = s
        for path in ProjectDocs.linkedPaths(in: s) {
            let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            out = out.replacingOccurrences(of: "](\(path))", with: "](artel-doc:\(enc))")
            out = out.replacingOccurrences(of: "](./\(path))", with: "](artel-doc:\(enc))")
            out = out.replacingOccurrences(of: "@\(path)", with: "[@\(path)](artel-doc:\(enc))")
            out = out.replacingOccurrences(of: "[[@\(path)](artel-doc:\(enc))]", with: "[@\(path)]")
        }
        return out
    }

    /// The relative path of an `artel-doc:` link, or nil for other links.
    static func docPath(_ url: URL) -> String? {
        guard url.scheme == "artel-doc" else { return nil }
        let raw = url.absoluteString.dropFirst("artel-doc:".count)
        return String(raw).removingPercentEncoding ?? String(raw)
    }
}

/// How a markdown document is previewed (MarkdownWebView) and where its links and images resolve.
struct MarkdownPreviewSource {
    /// Served to the preview for relative images and diagrams; nil = none.
    var root: URL?
    /// The document's folder relative to `root`.
    var baseDir = ""
    var documentID: String
    /// `@path` references and root-relative links become `artel-doc:` links (task texts, CLAUDE.md).
    var linkReferences = false
    var mdx = false
    var highlight: String?
    var anchor: String?
    var emptyText = "Empty"
    /// Link clicked, as written (`artel-doc:` for references).
    var openLink: (String) -> Void
    /// "Ask the agent" in the context menu of a selection.
    var askAgent: ((DocsPrompt.Fragment) -> Void)?
}

/// A markdown document: always the rendered preview, the source editor while `editing`.
struct MarkdownPane: View {
    @Binding var text: String
    var editing: Bool
    var source: MarkdownPreviewSource
    var insertion: Binding<String?> = .constant(nil)
    var referencesForDrop: (([URL]) -> [String])?
    var pasteImage: ((Data) -> String?)?
    var completion: LinkCompletionSource?
    var onExit: (() -> Void)?
    var onSelection: ((NSRange) -> Void)?

    var body: some View {
        if editing {
            MarkdownTextEditor(text: $text, insertion: insertion, referencesForDrop: referencesForDrop,
                               pasteImage: pasteImage, completion: completion, onExit: onExit, onSelection: onSelection)
        } else {
            let front = FrontMatter.parse(text)
            let body = source.linkReferences ? MarkdownPreview.linkImports(front.body) : front.body
            MarkdownWebView(
                options: MarkdownRenderOptions(markdown: body, lineOffset: front.bodyLine, title: front.fields["title"],
                                               mdx: source.mdx, highlight: source.highlight, anchor: source.anchor,
                                               emptyText: source.emptyText,
                                               baseDir: source.baseDir),
                root: source.root, documentID: source.documentID, onLink: source.openLink, onSelection: nil,
                askAgent: source.askAgent.map { ask in
                    { selection in
                        ask(DocsPrompt.fragment(source: text, firstLine: selection.firstLine, lastLine: selection.lastLine,
                                                selectedText: selection.text))
                    }
                })
        }
    }
}

/// Edit / done toggle shown above a markdown document. While editing: ⌘S saves, Esc and ⌘⏎ finish (see the editor).
struct MarkdownEditButton: View {
    var editing: Bool
    var dirty: Bool
    var canSave = true
    /// ⌘⏎ on "Done" (editors that don't handle it themselves, like the drawing editor).
    var doneShortcut = false
    var edit: () -> Void
    var done: () -> Void
    var save: () -> Void
    var discard: () -> Void

    var body: some View {
        if editing {
            if dirty {
                Button("Discard Changes", action: discard)
                    .help("Revert to the text on disk and stop editing")
            }
            Button("Save", action: save)
                .keyboardShortcut("s")
                .disabled(!dirty || !canSave)
                .help("Save (⌘S)")
            Button(action: done) { Label("Done", systemImage: "checkmark") }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
                .keyboardShortcut(doneShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .help(doneShortcut ? "Save and return (⌘⏎)" : "Save and return to the preview (⌘⏎ or Esc)")
        } else {
            Button(action: edit) { Label("Edit", systemImage: "pencil") }
                .keyboardShortcut("e")
                .help("Edit the source text (⌘E)")
        }
    }
}

/// VS Code-like dot for a document with unsaved changes.
struct UnsavedDot: View {
    var body: some View {
        Circle().fill(Color.primary.opacity(0.75)).frame(width: 7, height: 7)
            .help("There are unsaved changes")
            .accessibilityLabel("Unsaved")
    }
}
