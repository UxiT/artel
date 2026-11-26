import Foundation

/// The project's documentation site: a folder of markdown pages laid out the way Docusaurus does it
/// (docs/SPEC.md §4.9). Folders are sections, `.md`/`.mdx` files are pages, `.excalidraw` files are diagram pages.
/// Order and labels come from frontmatter (`sidebar_position`, `sidebar_label`, `title`) and `_category_.json|yml`.
public struct DocsNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case page, diagram, category }

    public var kind: Kind
    /// Relative to the project root.
    public var path: String
    public var title: String
    public var position: Double?
    /// Category only: the page shown when the section itself is opened (`index.md`, `README.md`, `<folder>.md`).
    public var indexPath: String?
    public var children: [DocsNode]?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var isCategory: Bool { kind == .category }

    public init(kind: Kind, path: String, title: String, position: Double? = nil, indexPath: String? = nil,
                children: [DocsNode]? = nil) {
        self.kind = kind
        self.path = path
        self.title = title
        self.position = position
        self.indexPath = indexPath
        self.children = children
    }
}

public enum DocsSite {
    public static let pageExtensions: Set<String> = ["md", "mdx", "markdown"]
    public static let diagramExtension = "excalidraw"
    /// Folders a documentation site usually lives in, most likely first.
    public static let candidates = ["docs", "documentation", "website/docs", "doc"]
    public static let defaultFolder = "docs"

    public static func isPage(_ path: String) -> Bool {
        pageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isDiagram(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == diagramExtension
    }

    /// The docs folder of a project without an explicit choice: a Docusaurus site's `docs/`, else the first
    /// existing candidate folder. nil = the project has no documentation yet.
    public static func detect(root: URL) -> String? {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(p).path, isDirectory: &d) && d.boolValue
        }
        for site in ["", "website/"] {
            let configs = ["js", "ts", "mjs", "cjs"].map { "\(site)docusaurus.config.\($0)" }
            if configs.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }), isDir(site + "docs") {
                return site + "docs"
            }
        }
        return candidates.first(where: isDir)
    }

    /// Normalizes a folder typed or picked by the operator: relative to the project, no `..`, no trailing slash.
    /// "" and "." mean the project root itself.
    public static func normalizeFolder(_ raw: String, root: URL) -> String? {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = root.standardizedFileURL.path
        if p.hasPrefix("/") {
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            guard std == rootPath || std.hasPrefix(rootPath + "/") else { return nil }
            p = String(std.dropFirst(rootPath.count))
        }
        p = (p as NSString).standardizingPath
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        if p == "." { p = "" }
        guard !p.hasPrefix(".."), !p.contains("/../") else { return nil }
        return p
    }

    // MARK: - Tree

    /// The site's sidebar tree. Files and folders starting with `_` or `.` are skipped (Docusaurus partials),
    /// as are folders without pages (asset folders).
    public static func tree(root: URL, folder: String) -> [DocsNode] {
        let base = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        return children(of: base, rel: folder, depth: 0)
    }

    static func children(of dir: URL, rel: String, depth: Int) -> [DocsNode] {
        guard depth < 8 else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var nodes: [DocsNode] = []
        for name in names where !name.hasPrefix(".") && !name.hasPrefix("_") {
            let url = dir.appendingPathComponent(name)
            let path = rel.isEmpty ? name : rel + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if name == "node_modules" { continue }
                let kids = children(of: url, rel: path, depth: depth + 1)
                let category = Category.read(dir: url)
                let index = indexPage(in: url, rel: path, folderName: name)
                let pages = kids.filter { $0.path != index }
                guard !pages.isEmpty || index != nil else { continue }
                let indexFront = index.flatMap {
                    try? String(contentsOf: url.appendingPathComponent(($0 as NSString).lastPathComponent), encoding: .utf8)
                }.map(FrontMatter.parse)
                nodes.append(DocsNode(kind: .category, path: path,
                                      title: category.label ?? indexFront?.fields["sidebar_label"] ?? prettify(name),
                                      position: category.position ?? indexFront.flatMap { Double($0.fields["sidebar_position"] ?? "") },
                                      indexPath: index, children: pages))
            } else if isPage(name) {
                // The folder's index page is attached to the category, not listed under it (see the folder branch).
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let front = FrontMatter.parse(text)
                nodes.append(DocsNode(kind: .page, path: path, title: pageTitle(front: front, fileName: name),
                                      position: Double(front.fields["sidebar_position"] ?? "")))
            } else if isDiagram(name) {
                nodes.append(DocsNode(kind: .diagram, path: path, title: prettify((name as NSString).deletingPathExtension)))
            }
        }
        return nodes.sorted(by: order)
    }

    static func indexPage(in dir: URL, rel: String, folderName: String) -> String? {
        let fm = FileManager.default
        for base in ["index", "README", "readme", folderName] {
            for ext in ["md", "mdx"] where fm.fileExists(atPath: dir.appendingPathComponent("\(base).\(ext)").path) {
                return rel + "/\(base).\(ext)"
            }
        }
        return nil
    }

    static func order(_ a: DocsNode, _ b: DocsNode) -> Bool {
        switch (a.position, b.position) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Sidebar title of a page: `sidebar_label`, `title`, the first `# heading`, else the file name.
    public static func pageTitle(front: FrontMatter, fileName: String) -> String {
        if let l = front.fields["sidebar_label"], !l.isEmpty { return l }
        if let t = front.fields["title"], !t.isEmpty { return t }
        if let h = firstHeading(front.body) { return h }
        return prettify((fileName as NSString).deletingPathExtension)
    }

    public static func firstHeading(_ text: String) -> String? {
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence, t.hasPrefix("# ") {
                let h = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return h.isEmpty ? nil : h
            }
        }
        return nil
    }

    /// `getting-started` → `Getting started`; `01-intro` → `Intro` (Docusaurus strips number prefixes too).
    public static func prettify(_ name: String) -> String {
        var s = name
        if let r = s.range(of: #"^\d+[-_. ]+"#, options: .regularExpression), r.upperBound < s.endIndex { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = s.first else { return name }
        return first.uppercased() + s.dropFirst()
    }

    /// Every page and diagram of the tree, depth first (category index pages included).
    public static func allPages(_ nodes: [DocsNode]) -> [DocsNode] {
        nodes.flatMap { node -> [DocsNode] in
            guard node.isCategory else { return [node] }
            let index = node.indexPath.map { DocsNode(kind: .page, path: $0, title: node.title) }
            return (index.map { [$0] } ?? []) + allPages(node.children ?? [])
        }
    }

    /// All categories (folders) of the tree, depth first.
    public static func allCategories(_ nodes: [DocsNode]) -> [DocsNode] {
        nodes.filter(\.isCategory).flatMap { [$0] + allCategories($0.children ?? []) }
    }

    /// The page to open first: the root index page, else the first page of the tree.
    public static func homePage(root: URL, folder: String, tree: [DocsNode]) -> String? {
        let dir = folder.isEmpty ? root : root.appendingPathComponent(folder)
        if let index = indexPage(in: dir, rel: folder, folderName: (folder as NSString).lastPathComponent) {
            return folder.isEmpty ? String(index.dropFirst()) : index
        }
        return allPages(tree).first { $0.kind == .page }?.path ?? allPages(tree).first?.path
    }

    // MARK: - Creating

    /// A file name for a new page or folder: transliterated to Latin, lower case, words joined with `-`.
    public static func slug(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? title
        var out = ""
        var dash = false
        for ch in latin.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                dash = false
            } else if !dash && !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "page" : out
    }

    /// A path inside `folder` for a new page titled `title` that doesn't clash with an existing file.
    public static func newPagePath(title: String, folder: String, root: URL, fileName: String? = nil) -> String {
        var base = fileName.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? slug(title)
        if base.contains("/") || base.hasPrefix(".") { base = slug(base) }
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() }.flatMap { pageExtensions.contains($0) ? $0 : nil } ?? "md"
        return unique(folder: folder, base: base, ext: ext, root: root)
    }

    public static func newFolderPath(title: String, folder: String, root: URL) -> String {
        unique(folder: folder, base: slug(title), ext: nil, root: root)
    }

    static func unique(folder: String, base: String, ext: String?, root: URL) -> String {
        let fm = FileManager.default
        var n = 1
        while true {
            let name = (n == 1 ? base : "\(base)-\(n)") + (ext.map { ".\($0)" } ?? "")
            let path = folder.isEmpty ? name : folder + "/" + name
            if !fm.fileExists(atPath: root.appendingPathComponent(path).path) { return path }
            n += 1
        }
    }

    public static func newPageText(title: String) -> String { "# \(title)\n\n" }

    /// Content of `index.md` for a freshly created documentation folder.
    public static func welcomePage(projectName: String) -> String {
        """
        ---
        sidebar_position: 1
        ---

        # \(projectName)

        Документация проекта. Страницы — markdown-файлы этой папки, разделы — вложенные папки.
        Порядок в боковой панели задаёт `sidebar_position` в начале страницы, подпись раздела — `_category_.json`.

        ```mermaid
        flowchart LR
          Оператор -->|пишет| Документация
          Агент -->|дополняет| Документация
        ```

        """
    }

    /// Creates a section folder with a `_category_.json` holding its label.
    public static func createCategory(at path: String, label: String, root: URL) throws {
        let dir = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: ["label": label], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: dir.appendingPathComponent("_category_.json"))
    }

    // MARK: - Category metadata

    public struct Category: Equatable, Sendable {
        public var label: String?
        public var position: Double?

        static func read(dir: URL) -> Category {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("_category_.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return Category(label: obj["label"] as? String, position: (obj["position"] as? NSNumber)?.doubleValue)
            }
            for name in ["_category_.yml", "_category_.yaml"] {
                if let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                    let f = FrontMatter.parseYAML(text)
                    return Category(label: f["label"], position: f["position"].flatMap(Double.init))
                }
            }
            return Category()
        }
    }
}

/// `---`-delimited YAML frontmatter at the top of a page. Only flat `key: value` pairs are read (what the sidebar
/// needs); nested values are skipped.
public struct FrontMatter: Equatable, Sendable {
    public var fields: [String: String]
    /// The page without its frontmatter.
    public var body: String
    /// How many source lines the frontmatter takes: the body's line 0 is this line of the file.
    public var bodyLine: Int

    public static func parse(_ text: String) -> FrontMatter {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return FrontMatter(fields: [:], body: text, bodyLine: 0) }
        let yaml = lines[1..<end].joined(separator: "\n")
        return FrontMatter(fields: parseYAML(yaml), body: lines[(end + 1)...].joined(separator: "\n"), bodyLine: end + 1)
    }

    static func parseYAML(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}
