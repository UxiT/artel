import Foundation

/// A node of the project file tree. Directories have `children` (possibly empty), files have nil.
public struct FileNode: Identifiable, Hashable, Sendable {
    /// Relative to the project root; "" for the root itself.
    public var path: String
    public var name: String
    public var children: [FileNode]?

    public var id: String { path }
    public var isDirectory: Bool { children != nil }

    public init(path: String, name: String, children: [FileNode]?) {
        self.path = path
        self.name = name
        self.children = children
    }
}

/// The project's files as a tree: what git would track (honours .gitignore) plus the project docs.
public enum ProjectFiles {
    /// Safety cap for huge repositories.
    public static let maxFiles = 50_000
    /// Skipped by the fallback scan of a folder that isn't a git repository.
    static let skippedFolders: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv", "venv",
                                              "__pycache__", "target", "dist", ".gradle", ".idea"]

    /// Relative paths of the project's files: tracked + untracked-not-ignored (`git ls-files -co --exclude-standard`),
    /// or a filesystem scan when git is unavailable or the folder isn't a repository.
    public static func list(root: URL, git: String?) -> [String] {
        if let git, let r = try? Shell.run(git, ["-C", root.path, "ls-files", "-z", "--cached", "--others",
                                                 "--exclude-standard", "--deduplicate"], timeout: 30), r.ok {
            let fm = FileManager.default
            var out: [String] = []
            for p in r.stdout.split(separator: "\0") {
                if out.count >= maxFiles { break }
                let path = String(p)
                // Deleted-but-tracked files and submodule entries (directories) are skipped.
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDir), !isDir.boolValue else { continue }
                out.append(path)
            }
            // Nothing from git (e.g. the folder is ignored by an enclosing repository): fall back to the scan.
            if !out.isEmpty { return out }
        }
        return scan(root: root)
    }

    static func scan(root: URL) -> [String] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            if out.count >= maxFiles { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if skippedFolders.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if url.lastPathComponent == ".DS_Store" { continue }
            // The file's own location, not its symlink target.
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            out.append(String(path.dropFirst(prefix.count)))
        }
        return out
    }

    /// Builds the tree from relative file paths: folders first, then files, each in Finder order.
    public static func tree(_ paths: [String]) -> [FileNode] {
        final class Dir {
            var dirs: [String: Dir] = [:]
            var files: Set<String> = []
        }
        let root = Dir()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard let file = parts.last, !parts.contains(".."), !parts.contains(".") else { continue }
            var dir = root
            for part in parts.dropLast() {
                if let d = dir.dirs[part] { dir = d } else { let d = Dir(); dir.dirs[part] = d; dir = d }
            }
            if dir.dirs[file] == nil { dir.files.insert(file) }
        }
        func order(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        func nodes(_ dir: Dir, prefix: String) -> [FileNode] {
            let folders = dir.dirs.keys.sorted(by: order).map { name -> FileNode in
                let path = prefix + name
                return FileNode(path: path, name: name, children: nodes(dir.dirs[name]!, prefix: path + "/"))
            }
            let files = dir.files.subtracting(dir.dirs.keys).sorted(by: order).map {
                FileNode(path: prefix + $0, name: $0, children: nil)
            }
            return folders + files
        }
        return nodes(root, prefix: "")
    }

    /// Folders that contain `path`, outermost first: "a/b/c.md" → ["a", "a/b"].
    public static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }
}
