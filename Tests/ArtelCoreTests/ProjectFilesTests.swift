import Foundation
import Testing
@testable import ArtelCore

@Suite struct ProjectFilesTests {
    @Test func treePutsFoldersFirstInFinderOrder() {
        let nodes = ProjectFiles.tree(["b.txt", "docs/arch.md", "a.txt", "docs/sub/api.md", "file10", "file2", "docs/arch.md"])
        #expect(nodes.map(\.name) == ["docs", "a.txt", "b.txt", "file2", "file10"])
        let docs = nodes[0]
        #expect(docs.isDirectory && docs.path == "docs")
        #expect(docs.children?.map(\.path) == ["docs/sub", "docs/arch.md"])
        #expect(docs.children?[0].children?.map(\.path) == ["docs/sub/api.md"])
        #expect(nodes[1].children == nil)
    }

    @Test func treeSkipsTraversal() {
        #expect(ProjectFiles.tree(["../x", "a/./b", "ok"]).map(\.name) == ["ok"])
    }

    @Test func ancestors() {
        #expect(ProjectFiles.ancestors(of: "a/b/c.md") == ["a", "a/b"])
        #expect(ProjectFiles.ancestors(of: "c.md") == [])
    }

    @Test func listHonoursGitignore() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for f in ["src/main.swift", "node_modules/x/i.js", "README.md"] {
            try "x".write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try "node_modules/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        // Without a repository: the fallback scan skips heavy folders.
        #expect(Set(ProjectFiles.list(root: root, git: nil)) == [".gitignore", "README.md", "src/main.swift"])
        // In a repository: git decides what is ignored.
        _ = try Shell.run("/usr/bin/git", ["-C", root.path, "init", "-q"])
        #expect(Set(ProjectFiles.list(root: root, git: "/usr/bin/git")) == [".gitignore", "README.md", "src/main.swift"])
    }

    @Test func scanKeepsSymlinkLocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("docs/real.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("notes/link.md"),
                                  withDestinationURL: root.appendingPathComponent("docs/real.md"))
        #expect(Set(ProjectFiles.scan(root: root)) == ["docs/real.md", "notes/link.md"])
    }
}
