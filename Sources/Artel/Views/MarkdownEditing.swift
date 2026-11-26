import ArtelCore
import AppKit
import MarkdownUI
import STTextView
import SwiftUI

/// What the page editor can complete after `](` and `[[`: the documentation pages, linked relative to `page`.
struct LinkCompletionSource {
    var page: String
    var pages: [(path: String, title: String)]
}

/// Markdown text editor (STTextView, TextKit 2) with light syntax highlighting.
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

    final class EditorView: STTextView {
        var referencesForDrop: (([URL]) -> [String])?
        var pasteImage: ((Data) -> String?)?
        var onExit: (() -> Void)?

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            super.readablePasteboardTypes + [.fileURL, .URL]
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
            guard !urls.isEmpty, let refs = referencesForDrop?(urls), !refs.isEmpty else {
                return super.performDragOperation(sender)
            }
            // draggingUpdated has already moved the caret under the pointer.
            insertText(refs.joined(separator: "\n"), replacementRange: selectedRange())
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

        /// Esc leaves the editor (unless the completion list is open).
        override func cancelOperation(_ sender: Any?) {
            if let onExit, !isCompletionActive { onExit() } else { super.cancelOperation(sender) }
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
    }

    /// A row of the link completion list.
    final class CompletionItem: NSObject, STCompletionItem {
        let id = UUID()
        let candidate: DocsCompletion.Candidate
        init(_ candidate: DocsCompletion.Candidate) { self.candidate = candidate }

        var view: NSView {
            let title = NSTextField(labelWithString: candidate.title)
            title.font = .systemFont(ofSize: NSFont.systemFontSize)
            title.lineBreakMode = .byTruncatingTail
            let path = NSTextField(labelWithString: candidate.path)
            path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            let stack = NSStackView(views: [title, path])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return stack
        }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var parent: MarkdownTextEditor
        var isUpdating = false
        var appliedFonts: (FontChoice, FontChoice)?
        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textViewDidChangeText(_ notification: Notification) {
            MainActor.assumeIsolated { changed(notification) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? EditorView, let onSelection = parent.onSelection else { return }
            let range = tv.selectedRange()
            DispatchQueue.main.async { onSelection(range) }
        }

        private func changed(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? EditorView else { return }
            let s = tv.text ?? ""
            MarkdownHighlighter.apply(to: tv, font: parent.font, code: parent.codeFont)
            if parent.text != s { parent.text = s }
            guard parent.completion != nil else { return }
            if DocsCompletion.query(in: s, caret: tv.selectedRange().location) != nil {
                DispatchQueue.main.async { tv.complete(nil) }
            } else if tv.isCompletionActive {
                tv.cancelComplete(nil)
            }
        }

        func textView(_ textView: STTextView, completionItemsAtLocation location: any NSTextLocation) -> [any STCompletionItem]? {
            guard let source = parent.completion,
                  let query = DocsCompletion.query(in: textView.text ?? "", caret: textView.selectedRange().location) else { return nil }
            return DocsCompletion.candidates(query, pages: source.pages, fromPage: source.page).map(CompletionItem.init)
        }

        func textView(_ textView: STTextView, insertCompletionItem item: any STCompletionItem) {
            defer { textView.cancelComplete(nil) }
            guard let item = item as? CompletionItem,
                  let query = DocsCompletion.query(in: textView.text ?? "", caret: textView.selectedRange().location) else { return }
            textView.insertText(item.candidate.insertion, replacementRange: query.range)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The editor takes whatever space it is offered. Left to the default, SwiftUI sizes the scroll view through
    /// Auto Layout and reaches STTextView's intrinsic size (the text laid out at the current width): in a split view
    /// the column's min size then follows the line wrapping, the window loops on update-constraints passes and
    /// AppKit throws (the Projects section crashed on opening).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 160))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        let tv = scroll.documentView as! EditorView
        tv.isHorizontallyResizable = false  // wrap lines
        tv.font = MarkdownHighlighter.baseFont(font)
        tv.textColor = .textColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.textContainer.lineFragmentPadding = 10
        tv.textDelegate = context.coordinator
        configure(tv)
        tv.text = text
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
        if (tv.text ?? "") != text && !tv.hasMarkedText() {
            let selection = tv.selectedRange()
            context.coordinator.isUpdating = true
            tv.text = text
            context.coordinator.isUpdating = false
            MarkdownHighlighter.apply(to: tv, font: font, code: codeFont)
            context.coordinator.appliedFonts = (font, codeFont)
            if selection.upperBound <= (text as NSString).length { tv.textSelection = selection }
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

    @MainActor static func apply(to tv: STTextView, font: FontChoice, code codeChoice: FontChoice) {
        let text = tv.text ?? ""
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }
        let base = baseFont(font)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let code = codeFont(codeChoice, editor: font)
        let heading = NSFontManager.shared.convert(
            FontChoice(family: font.family, size: font.size + 2).nsFont(monospaced: false), toHaveTrait: .boldFontMask)
        tv.addAttributes([.font: base, .foregroundColor: NSColor.textColor, .backgroundColor: NSColor.clear], range: full)
        for (re, style) in rules {
            for m in re.matches(in: text, range: full) {
                let r = m.range
                switch style {
                case .heading:
                    tv.addAttributes([.font: heading,
                                      .foregroundColor: NSColor.labelColor], range: r)
                case .bold: tv.addAttributes([.font: bold], range: r)
                case .code: tv.addAttributes([.font: code, .foregroundColor: NSColor.systemPink], range: r)
                case .marker: tv.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: r)
                case .quote: tv.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: r)
                case .link: tv.addAttributes([.foregroundColor: NSColor.linkColor], range: r)
                case .reference: tv.addAttributes([.font: code, .foregroundColor: NSColor.linkColor], range: r)
                case .comment: tv.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: r)
                case .codeBlock:
                    tv.addAttributes([.font: code, .foregroundColor: NSColor.systemPink,
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
    var emptyText = "Пусто"
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
    var edit: () -> Void
    var done: () -> Void
    var save: () -> Void
    var discard: () -> Void

    var body: some View {
        if editing {
            if dirty {
                Button("Отменить изменения", action: discard)
                    .help("Вернуть текст как на диске и выйти из редактирования")
            }
            Button("Сохранить", action: save)
                .keyboardShortcut("s")
                .disabled(!dirty || !canSave)
                .help("Сохранить (⌘S)")
            Button(action: done) { Label("Готово", systemImage: "checkmark") }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
                .help("Сохранить и вернуться к просмотру (⌘⏎ или Esc)")
        } else {
            Button(action: edit) { Label("Редактировать", systemImage: "pencil") }
                .keyboardShortcut("e")
                .help("Редактировать исходный текст (⌘E)")
        }
    }
}

/// VS Code-like dot for a document with unsaved changes.
struct UnsavedDot: View {
    var body: some View {
        Circle().fill(Color.primary.opacity(0.75)).frame(width: 7, height: 7)
            .help("Есть несохранённые изменения")
            .accessibilityLabel("Не сохранено")
    }
}
