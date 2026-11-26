import Foundation

/// A markdown file that shapes the agent's context: CLAUDE.md, specs it links to, rules.
public struct ProjectDoc: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case description, spec, context
        public var title: String {
            switch self {
            case .description: "Description"
            case .spec: "Specs"
            case .context: "Context"
            }
        }
    }

    public var kind: Kind
    /// Relative to the project root.
    public var path: String
    /// Referenced from CLAUDE.md (`@path` or a markdown link). Context files load on their own.
    public var linked: Bool
    public var exists: Bool

    public init(kind: Kind, path: String, linked: Bool, exists: Bool) {
        self.kind = kind
        self.path = path
        self.linked = linked
        self.exists = exists
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum ProjectDocs {
    /// Folders scanned for spec files besides what CLAUDE.md links to.
    public static let specFolders = ["docs", "specs", "spec"]
    public static let claudeMD = "CLAUDE.md"
    nonisolated(unsafe) static let importRE = try! NSRegularExpression(pattern: #"(?<![\w/@.])@([\w./-]+)"#)
    nonisolated(unsafe) static let linkRE = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)

    /// Paths CLAUDE.md references: `@docs/arch.md` imports and `[text](docs/arch.md)` links.
    /// Only relative paths inside the project; URLs, anchors and home paths are skipped.
    public static func linkedPaths(in text: String) -> [String] {
        var found: [String] = []
        func add(_ raw: Substring) {
            var p = String(raw)
            if let hash = p.firstIndex(of: "#") { p = String(p[..<hash]) }
            if p.hasPrefix("./") { p.removeFirst(2) }
            while p.hasSuffix(".") || p.hasSuffix(",") || p.hasSuffix(":") { p.removeLast() }
            guard !p.isEmpty, !p.hasPrefix("/"), !p.hasPrefix("~"), !p.contains("://"), !p.hasPrefix("mailto:"),
                  (p as NSString).pathExtension.isEmpty == false else { return }
            let normalized = (p as NSString).standardizingPath
            guard !normalized.hasPrefix(".."), !found.contains(normalized) else { return }
            found.append(normalized)
        }
        // Skip fenced code blocks: examples there are not imports.
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let ns = line as NSString
            for re in [importRE, linkRE] {
                for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    add(Substring(ns.substring(with: m.range(at: 1))))
                }
            }
        }
        return found
    }

    public static func discover(root: URL) -> [ProjectDoc] {
        let fm = FileManager.default
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(p).path) }
        let linked = importClosure(root: root)

        var docs = [ProjectDoc(kind: .description, path: claudeMD, linked: true, exists: exists(claudeMD))]
        let contextPaths = contextFiles(root: root)
        for p in linked where p != claudeMD && !contextPaths.contains(p) {
            docs.append(ProjectDoc(kind: .spec, path: p, linked: true, exists: exists(p)))
        }
        for p in markdownFiles(root: root, in: specFolders, depth: 3) where !linked.contains(p) {
            docs.append(ProjectDoc(kind: .spec, path: p, linked: false, exists: true))
        }
        for p in contextPaths {
            docs.append(ProjectDoc(kind: .context, path: p, linked: linked.contains(p), exists: true))
        }
        return docs
    }

    /// Everything reachable from CLAUDE.md: Claude Code follows imports inside imported files too (up to 5 hops).
    /// Paths of nested imports are relative to the project root here, as in Artel's own `@docs/…` convention.
    static func importClosure(root: URL, maxDepth: Int = 5) -> [String] {
        var seen: [String] = []
        var frontier = [claudeMD]
        for _ in 0..<maxDepth where !frontier.isEmpty {
            var next: [String] = []
            for file in frontier {
                guard let url = url(file, root: root) ?? (file == claudeMD ? root.appendingPathComponent(file) : nil),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for p in linkedPaths(in: text) where p != claudeMD && !seen.contains(p) {
                    seen.append(p)
                    if (p as NSString).pathExtension.lowercased() == "md" { next.append(p) }
                }
            }
            frontier = next
        }
        return seen
    }

    /// Files Claude Code loads by itself: local memory, project rules, AGENTS.md.
    static func contextFiles(root: URL) -> [String] {
        let fm = FileManager.default
        var out = ["CLAUDE.local.md", ".claude/CLAUDE.md", "AGENTS.md"]
            .filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        out += markdownFiles(root: root, in: [".claude/rules"], depth: 4)
        return out
    }

    static func markdownFiles(root: URL, in folders: [String], depth: Int) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for folder in folders {
            let base = root.appendingPathComponent(folder).resolvingSymlinksInPath()
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > depth { e.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "md" else { continue }
                let parts = url.resolvingSymlinksInPath().pathComponents
                guard parts.starts(with: base.pathComponents) else { continue }
                out.append(([folder] + parts.dropFirst(base.pathComponents.count)).joined(separator: "/"))
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Adds `@path` to CLAUDE.md: into a Specs (or legacy Russian «Спеки») section if there is one, else a new section at the end.
    public static func link(_ path: String, into text: String) -> String {
        if linkedPaths(in: text).contains(path) { return text }
        var lines = text.components(separatedBy: "\n")
        let isSpecHeading: (String) -> Bool = { l in
            let t = l.trimmingCharacters(in: .whitespaces).lowercased()
            return t.hasPrefix("#") && (t.contains("spec") || t.contains("documentation") || t.contains("спек") || t.contains("документац"))
        }
        if let h = lines.firstIndex(where: isSpecHeading) {
            var end = h + 1
            while end < lines.count && !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("#") { end += 1 }
            var insert = end
            while insert > h + 1 && lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
            lines.insert("- @\(path)", at: insert)
            return lines.joined(separator: "\n")
        }
        var t = text
        while t.hasSuffix("\n") { t.removeLast() }
        return t + "\n\n## Specs\n- @\(path)\n"
    }

    /// Relative path for a new doc: `docs/<name>.md` for specs, `.claude/rules/<name>.md` for context.
    public static func newPath(kind: ProjectDoc.Kind, name: String) -> String? {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.contains(".."), !n.hasPrefix("/") else { return nil }
        if (n as NSString).pathExtension.lowercased() != "md" { n += ".md" }
        switch kind {
        case .description: return claudeMD
        case .spec: return n.contains("/") ? n : "docs/" + n
        case .context: return n.contains("/") ? n : ".claude/rules/" + n
        }
    }

    /// Resolves a relative doc path, refusing anything outside the project.
    public static func url(_ path: String, root: URL) -> URL? {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        return url.path.hasPrefix(rootPath + "/") ? url : nil
    }
}
