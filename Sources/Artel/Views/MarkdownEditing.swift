import ArtelCore
import AppKit
import MarkdownUI
import STTextView
import SwiftUI

/// Global "text / preview" choice for every markdown document in the app (task text, project docs, artifacts).
enum MarkdownMode {
    static let key = "markdown.preview"
}

/// Segmented "Текст | Просмотр" bound to the global choice.
struct MarkdownModePicker: View {
    @AppStorage(MarkdownMode.key) private var preview = false

    var body: some View {
        Picker("", selection: $preview) {
            Text("Текст").tag(false)
            Text("Просмотр").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Режим для всех документов")
    }
}

/// Markdown text editor (STTextView, TextKit 2) with light syntax highlighting.
/// Dropped files/URLs become references at the drop point via `referencesForDrop`.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Set by the parent to insert text at the cursor (toolbar buttons).
    var insertion: Binding<String?> = .constant(nil)
    var referencesForDrop: (([URL]) -> [String])?
    /// Editor font; code spans use the code font's family at the editor's size.
    var font: FontChoice = AppFonts.shared.settings.editor
    var codeFont: FontChoice = AppFonts.shared.settings.code

    final class EditorView: STTextView {
        var referencesForDrop: (([URL]) -> [String])?

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
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var parent: MarkdownTextEditor
        var isUpdating = false
        var appliedFonts: (FontChoice, FontChoice)?
        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textViewDidChangeText(_ notification: Notification) {
            MainActor.assumeIsolated { changed(notification) }
        }

        private func changed(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? EditorView else { return }
            let s = tv.text ?? ""
            MarkdownHighlighter.apply(to: tv, font: parent.font, code: parent.codeFont)
            if parent.text != s { parent.text = s }
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
        tv.referencesForDrop = referencesForDrop
        tv.text = text
        MarkdownHighlighter.apply(to: tv, font: font, code: codeFont)
        context.coordinator.appliedFonts = (font, codeFont)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? EditorView else { return }
        context.coordinator.parent = self
        tv.referencesForDrop = referencesForDrop
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

/// Editor or preview depending on the global mode.
struct MarkdownPane: View {
    @Binding var text: String
    var insertion: Binding<String?> = .constant(nil)
    var referencesForDrop: (([URL]) -> [String])?
    /// Handles `artel-doc:` links and other URLs clicked in the preview.
    var openLink: ((URL) -> Void)?
    @AppStorage(MarkdownMode.key) private var preview = false

    var body: some View {
        if preview {
            ScrollView {
                MarkdownPreview(text: text)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.openURL, OpenURLAction { url in
                if let openLink { openLink(url); return .handled }
                return .systemAction
            })
        } else {
            MarkdownTextEditor(text: $text, insertion: insertion, referencesForDrop: referencesForDrop)
        }
    }
}
