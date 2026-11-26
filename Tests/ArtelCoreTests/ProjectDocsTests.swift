import Foundation
import Testing
@testable import ArtelCore

@Suite struct ProjectDocsTests {
    @Test func linkedPathsFindsImportsAndLinks() {
        let text = """
        # P
        See @docs/arch.md, and [stack](./docs/stack.md#db). Mail me: a@b.com
        Web [x](https://example.com/a.md), home @~/notes.md, up @../x.md
        ```
        @docs/ignored.md
        ```
        Again @docs/arch.md
        """
        #expect(ProjectDocs.linkedPaths(in: text) == ["docs/arch.md", "docs/stack.md"])
    }

    @Test func discoverGroupsDocs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".claude/rules"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "# P\n## Описание\nx\n@docs/arch.md @docs/missing.md".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "see @docs/deep.md".write(to: root.appendingPathComponent("docs/arch.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("docs/deep.md"), atomically: true, encoding: .utf8)
        for f in [ "docs/sub/api.md", ".claude/rules/style.md", "AGENTS.md"] {
            try "x".write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        let docs = ProjectDocs.discover(root: root)
        #expect(docs.map(\.path) == ["CLAUDE.md", "docs/arch.md", "docs/missing.md", "docs/deep.md", "docs/sub/api.md", "AGENTS.md", ".claude/rules/style.md"])
        #expect(docs.first { $0.path == "docs/missing.md" }?.exists == false)
        #expect(docs.first { $0.path == "docs/sub/api.md" }?.linked == false)
        #expect(docs.first { $0.path == "AGENTS.md" }?.kind == .context)
    }

    @Test func linkInsertsIntoSpecSection() {
        let withSection = "# P\n\n## Спеки\n- @docs/a.md\n\n## Команды\nmake"
        #expect(ProjectDocs.link("docs/b.md", into: withSection) == "# P\n\n## Спеки\n- @docs/a.md\n- @docs/b.md\n\n## Команды\nmake")
        #expect(ProjectDocs.link("docs/b.md", into: "# P\n") == "# P\n\n## Specs\n- @docs/b.md\n")
        // An English Specs section is found too; "Docker" is not a docs heading.
        #expect(ProjectDocs.link("docs/b.md", into: "# P\n\n## Specs\n- @docs/a.md\n\n## Docker\nx")
                == "# P\n\n## Specs\n- @docs/a.md\n- @docs/b.md\n\n## Docker\nx")
        #expect(ProjectDocs.link("docs/a.md", into: withSection) == withSection)
    }

    @Test func pathsStayInsideProject() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        #expect(ProjectDocs.url("../etc/passwd", root: root) == nil)
        #expect(ProjectDocs.url("docs/a.md", root: root)?.path == "/tmp/proj/docs/a.md")
        #expect(ProjectDocs.newPath(kind: .spec, name: "arch") == "docs/arch.md")
        #expect(ProjectDocs.newPath(kind: .context, name: "style.md") == ".claude/rules/style.md")
        #expect(ProjectDocs.newPath(kind: .spec, name: "../x") == nil)
    }
}
