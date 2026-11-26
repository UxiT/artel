import Foundation

/// Relative links between documentation pages: resolving them, writing new ones, and keeping them valid when
/// pages or sections move.
public enum DocsLinks {
    /// `[text](target "title")`, `![alt](<a b.png>)`.
    nonisolated(unsafe) static let inlineRE = try! NSRegularExpression(pattern: #"\]\(\s*(<[^>\n]+>|[^)\s]+)(\s+"[^"\n]*")?\s*\)"#)
    /// `[id]: target` reference definitions.
    nonisolated(unsafe) static let referenceRE = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)"#)
    /// `@path` imports (CLAUDE.md style, relative to the project root).
    nonisolated(unsafe) static let importRE = try! NSRegularExpression(pattern: #"(?<![\w/@.])@([\w./-]+)"#)

    /// Directory of a project-relative file path ("" for the root).
    public static func directory(of path: String) -> String {
        let d = (path as NSString).deletingLastPathComponent
        return d == "." ? "" : d
    }

    /// Path from directory `fromDir` to `target`, both relative to the project root.
    public static func relative(from fromDir: String, to target: String) -> String {
        let a = fromDir.split(separator: "/").map(String.init)
        let b = target.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count && i < b.count - 1 && a[i] == b[i] { i += 1 }
        let up = Array(repeating: "..", count: a.count - i)
        return (up + b[i...]).joined(separator: "/")
    }

    /// A link target as written in a page → project-relative path (no anchor), or nil for URLs, anchors and
    /// absolute paths. `..` above the project root is refused.
    public static func resolve(_ target: String, fromPage page: String) -> String? {
        var t = target
        if t.hasPrefix("<") && t.hasSuffix(">") { t = String(t.dropFirst().dropLast()) }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if let q = t.firstIndex(of: "?") { t = String(t[..<q]) }
        guard !t.isEmpty, !t.hasPrefix("/"), !t.hasPrefix("~"), !t.contains(":") else { return nil }
        t = t.removingPercentEncoding ?? t
        let dir = directory(of: page)
        var parts = dir.split(separator: "/").map(String.init)
        for comp in t.split(separator: "/", omittingEmptySubsequences: true) {
            switch comp {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(comp))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// A markdown link target for `target` written inside `page`.
    public static func target(_ target: String, fromPage page: String) -> String {
        let rel = relative(from: directory(of: page), to: target)
        return rel.contains(" ") ? "<\(rel)>" : rel
    }

    // MARK: - Moving

    /// Where `path` ends up after moving `from` (a file or a folder) to `to`; nil if unaffected.
    public static func moved(_ path: String, from: String, to: String) -> String? {
        if path == from { return to }
        if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
        return nil
    }

    /// Rewrites the relative links of a page after a move. `oldPage` is where the page was (its links are relative
    /// to that), `newPage` where it is now; `map` gives the new place of any moved target.
    /// Fenced code is left alone. `@path` imports (project-root relative) are rewritten when `imports` is set.
    public static func rewrite(_ text: String, oldPage: String, newPage: String, imports: Bool = false,
                               map: (String) -> String?) -> String {
        var out = ""
        var inFence = false
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            var l = line
            if !inFence && !(trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")) {
                l = rewriteLine(line, oldPage: oldPage, newPage: newPage, map: map)
                if imports { l = rewriteImports(l, map: map) }
            }
            out += l
            if i < lines.count - 1 { out += "\n" }
        }
        return out
    }

    static func rewriteLine(_ line: String, oldPage: String, newPage: String, map: (String) -> String?) -> String {
        var result = line
        for re in [inlineRE, referenceRE] {
            let ns = result as NSString
            let matches = re.matches(in: result, range: NSRange(location: 0, length: ns.length))
            var s = result
            for m in matches.reversed() {
                let r = m.range(at: 1)
                let raw = ns.substring(with: r)
                guard let resolved = resolve(raw, fromPage: oldPage) else { continue }
                let newTarget = map(resolved) ?? resolved
                if newTarget == resolved && directory(of: oldPage) == directory(of: newPage) { continue }
                var bare = raw
                if bare.hasPrefix("<") && bare.hasSuffix(">") { bare = String(bare.dropFirst().dropLast()) }
                let anchor = bare.firstIndex(of: "#").map { String(bare[$0...]) } ?? ""
                var written = relative(from: directory(of: newPage), to: newTarget)
                if bare.contains("%20") { written = written.replacingOccurrences(of: " ", with: "%20") }
                written += anchor
                if written.contains(" ") { written = "<\(written)>" }
                guard written != raw else { continue }
                let range = Range(r, in: s)!
                s.replaceSubrange(range, with: written)
            }
            result = s
        }
        return result
    }

    static func rewriteImports(_ line: String, map: (String) -> String?) -> String {
        let ns = line as NSString
        var s = line
        for m in importRE.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
            var p = ns.substring(with: m.range(at: 1))
            while p.hasSuffix(".") || p.hasSuffix(",") || p.hasSuffix(":") { p.removeLast() }
            guard let to = map(p) else { continue }
            let r = NSRange(location: m.range(at: 1).location, length: (p as NSString).length)
            s.replaceSubrange(Range(r, in: s)!, with: to)
        }
        return s
    }

    /// Moves a page, diagram or section inside the project and fixes the links of every markdown file in `files`
    /// (project-relative, their paths before the move): links into the moved item, and the moved pages' own links.
    /// `importFiles` (CLAUDE.md and other context files) also get their `@path` imports rewritten.
    /// Returns the files whose text changed (paths after the move).
    @discardableResult
    public static func move(_ from: String, to: String, root: URL, files: [String], importFiles: Set<String> = []) throws -> [String] {
        guard from != to else { return [] }
        let fm = FileManager.default
        let src = root.appendingPathComponent(from)
        let dst = root.appendingPathComponent(to)
        guard !fm.fileExists(atPath: dst.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to])
        }
        guard !to.hasPrefix(from + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        let map: (String) -> String? = { moved($0, from: from, to: to) }
        var changed: [String] = []
        for old in files {
            let now = map(old) ?? old
            let url = root.appendingPathComponent(now)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let new = rewrite(text, oldPage: old, newPage: now, imports: importFiles.contains(old), map: map)
            if new != text {
                try new.write(to: url, atomically: true, encoding: .utf8)
                changed.append(now)
            }
        }
        return changed
    }
}

/// Full-text search over the documentation pages.
public enum DocsSearch {
    public struct Hit: Identifiable, Hashable, Sendable {
        public var path: String
        public var title: String
        /// 0-based line of the first match in the file.
        public var line: Int
        public var snippet: String
        public var matches: Int
        public var id: String { path }
    }

    /// Pages matching every word of `query` (case and diacritics insensitive), title matches first.
    public static func search(_ query: String, pages: [(path: String, title: String, text: String)]) -> [Hit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [(Hit, Int)] = []
        for page in pages {
            let hay = page.title + "\n" + page.text
            guard words.allSatisfy({ hay.range(of: $0, options: opts) != nil }) else { continue }
            let lines = page.text.components(separatedBy: "\n")
            let lineIndex = lines.firstIndex { l in words.contains { l.range(of: $0, options: opts) != nil } }
            var snippet = lineIndex.map { lines[$0].trimmingCharacters(in: .whitespaces) } ?? ""
            if snippet.count > 140, let w = words.first, let r = snippet.range(of: w, options: opts) {
                let start = snippet.index(r.lowerBound, offsetBy: -50, limitedBy: snippet.startIndex) ?? snippet.startIndex
                snippet = (start == snippet.startIndex ? "" : "…") + String(snippet[start...].prefix(140))
            }
            let count = words.reduce(0) { n, w in n + occurrences(of: w, in: page.text, options: opts) }
            let titleWords = words.filter { page.title.range(of: $0, options: opts) != nil }.count
            hits.append((Hit(path: page.path, title: page.title, line: lineIndex ?? 0, snippet: snippet, matches: count), titleWords))
        }
        return hits.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.matches != b.0.matches { return a.0.matches > b.0.matches }
            return a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
        }.map(\.0)
    }

    static func occurrences(of word: String, in text: String, options: String.CompareOptions) -> Int {
        var n = 0
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: word, options: options, range: range) {
            n += 1
            range = r.upperBound..<text.endIndex
        }
        return n
    }
}

/// Prompts for an agent asked to write or edit the documentation.
public enum DocsPrompt {
    public struct Fragment: Equatable, Sendable {
        /// 1-based, inclusive lines of the page file.
        public var firstLine: Int
        public var lastLine: Int
        public var text: String

        public init(firstLine: Int, lastLine: Int, text: String) {
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.text = text
        }
    }

    public static func make(instruction: String, docsFolder: String, page: String?, fragment: Fragment?) -> String {
        let folder = docsFolder.isEmpty ? "the project root" : "`\(docsFolder)/`"
        var out = "We are working on the project documentation in \(folder).\n"
        if let page { out += "Page: `\(page)`.\n" }
        if let fragment, let page {
            let lines = fragment.firstLine == fragment.lastLine ? "line \(fragment.firstLine)"
                : "lines \(fragment.firstLine)–\(fragment.lastLine)"
            out += "\nChange only this fragment of the page (\(lines) of `\(page)`), leave the rest as is:\n\n"
            let fence = fragment.text.contains("```") ? "~~~~" : "```"
            out += "\(fence)markdown\n\(fragment.text.trimmingCharacters(in: .newlines))\n\(fence)\n"
        }
        out += "\nTask: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        out += """

        Documentation rules:
        - Docusaurus-compatible Markdown. Pages are `.md` files in \(folder), sections are subfolders; a section's label goes in `_category_.json` (`{"label": "…", "position": 2}`), page order in `sidebar_position` in the frontmatter.
        - Diagrams as ```mermaid blocks; math as `$…$` and `$$…$$`; admonitions as `:::note`, `:::tip`, `:::info`, `:::warning`, `:::danger` … `:::`.
        - Links between pages are relative paths to `.md` files; put images in `assets/` next to the page.
        - Change only documentation files unless the task explicitly requires otherwise. Don't commit anything.
        """
        return out
    }

    /// A short session name for the workspace card.
    public static func sessionName(page: String?, fragment: Bool) -> String {
        guard let page else { return "Docs" }
        let name = ((page as NSString).lastPathComponent as NSString).deletingPathExtension
        return (fragment ? "Edit: " : "Docs: ") + name
    }
}

extension DocsPrompt {
    /// The fragment of `source` covered by a preview selection: the blocks' lines (0-based, end exclusive) when the
    /// preview knows them, else the lines where the selected text starts.
    public static func fragment(source: String, firstLine: Int?, lastLine: Int?, selectedText: String) -> Fragment {
        let lines = source.components(separatedBy: "\n")
        if let first = firstLine, first >= 0, first < lines.count {
            let end = min(max(lastLine ?? first + 1, first + 1), lines.count)
            var slice = Array(lines[first..<end])
            while slice.count > 1, slice.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { slice.removeLast() }
            return Fragment(firstLine: first + 1, lastLine: first + slice.count, text: slice.joined(separator: "\n"))
        }
        let selected = selectedText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let probe = selected.first { !$0.isEmpty } ?? ""
        if let start = lines.firstIndex(where: { !probe.isEmpty && $0.contains(probe) }) {
            let end = min(start + max(selected.count, 1), lines.count)
            return Fragment(firstLine: start + 1, lastLine: end, text: lines[start..<end].joined(separator: "\n"))
        }
        return Fragment(firstLine: 1, lastLine: max(lines.count, 1), text: selectedText)
    }

    /// The fragment covered by an editor selection (UTF-16 range), widened to whole lines.
    public static func fragment(source: String, range: NSRange) -> Fragment? {
        let ns = source as NSString
        guard range.length > 0, range.location + range.length <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: range)
        let before = ns.substring(to: lineRange.location)
        let first = before.components(separatedBy: "\n").count
        var text = ns.substring(with: lineRange)
        if text.hasSuffix("\n") { text.removeLast() }
        return Fragment(firstLine: first, lastLine: first + text.components(separatedBy: "\n").count - 1, text: text)
    }
}

/// Link completion in the page editor: after `](` it offers page paths, after `[[` whole links to pages.
public enum DocsCompletion {
    public enum Mode: Sendable { case path, wiki }

    public struct Query: Equatable, Sendable {
        public var mode: Mode
        public var text: String
        /// UTF-16 range the chosen item replaces.
        public var range: NSRange
    }

    public struct Candidate: Equatable, Sendable {
        public var title: String
        public var path: String
        public var insertion: String
    }

    nonisolated(unsafe) static let pathRE = try! NSRegularExpression(pattern: #"\]\(([^)\s]*)$"#)
    nonisolated(unsafe) static let wikiRE = try! NSRegularExpression(pattern: #"\[\[([^\]\n]*)$"#)

    /// What is being completed at `caret` (UTF-16 offset), if anything.
    public static func query(in text: String, caret: Int) -> Query? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: max(0, caret - 1), length: 0)).location
        let start = caret > 0 && ns.character(at: caret - 1) == 10 ? caret : lineStart
        let line = ns.substring(with: NSRange(location: start, length: caret - start))
        let lns = line as NSString
        let full = NSRange(location: 0, length: lns.length)
        if let m = wikiRE.firstMatch(in: line, range: full) {
            return Query(mode: .wiki, text: lns.substring(with: m.range(at: 1)),
                         range: NSRange(location: start + m.range.location, length: m.range.length))
        }
        if let m = pathRE.firstMatch(in: line, range: full) {
            let r = m.range(at: 1)
            return Query(mode: .path, text: lns.substring(with: r), range: NSRange(location: start + r.location, length: r.length))
        }
        return nil
    }

    /// Pages matching the query (title or path), the current page excluded, at most `limit`.
    public static func candidates(_ query: Query, pages: [(path: String, title: String)], fromPage page: String,
                                  limit: Int = 30) -> [Candidate] {
        let q = query.text.trimmingCharacters(in: .whitespaces)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return pages.filter { p in
            p.path != page && (q.isEmpty || p.title.range(of: q, options: opts) != nil || p.path.range(of: q, options: opts) != nil
                || DocsLinks.relative(from: DocsLinks.directory(of: page), to: p.path).hasPrefix(q))
        }.prefix(limit).map { p in
            let target = DocsLinks.target(p.path, fromPage: page)
            switch query.mode {
            case .path: return Candidate(title: p.title, path: p.path, insertion: target + ")")
            case .wiki: return Candidate(title: p.title, path: p.path, insertion: "[\(p.title)](\(target))")
            }
        }
    }
}
