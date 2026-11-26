import Foundation
import Testing
@testable import ArtelCore

private func makeSite(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("artel-docs-\(UUID().uuidString.prefix(8))")
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

private func read(_ root: URL, _ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

@Suite struct DocsFrontMatter {
    @Test func parsesFlatFieldsAndBodyLine() {
        let f = FrontMatter.parse("---\ntitle: \"Hello: world\"\nsidebar_position: 2 # first\ntags:\n  - a\n---\n# Body\n")
        #expect(f.fields["title"] == "Hello: world")
        #expect(f.fields["sidebar_position"] == "2")
        #expect(f.fields["tags"] == nil)
        #expect(f.body == "# Body\n")
        #expect(f.bodyLine == 6)
    }

    @Test func withoutFrontMatterTheBodyIsTheText() {
        let f = FrontMatter.parse("# Title\n---\n")
        #expect(f.fields.isEmpty)
        #expect(f.bodyLine == 0)
        #expect(f.body == "# Title\n---\n")
    }
}

@Suite struct DocsTree {
    @Test func ordersByPositionThenNameAndReadsCategories() throws {
        let root = try makeSite([
            "docs/index.md": "# Welcome\n",
            "docs/b.md": "---\nsidebar_position: 1\n---\n# Bee\n",
            "docs/a.md": "# A page\n",
            "docs/guide/_category_.json": #"{"label": "Руководство", "position": 0}"#,
            "docs/guide/setup.md": "---\nsidebar_label: Установка\n---\n# Setup\n",
            "docs/guide/index.md": "# Guide\n",
            "docs/_partial.md": "x",
            "docs/assets/pic.png": "png",
            "docs/flow.excalidraw": "{}",
            "docs/02-api/README.md": "# API\n",
        ])
        let tree = DocsSite.tree(root: root, folder: "docs")
        #expect(tree.map(\.title) == ["Руководство", "Bee", "Api", "A page", "Flow", "Welcome"])
        let guide = tree[0]
        #expect(guide.isCategory)
        #expect(guide.indexPath == "docs/guide/index.md")
        #expect(guide.children?.map(\.title) == ["Установка"])
        #expect(tree.first { $0.path == "docs/02-api" }?.indexPath == "docs/02-api/README.md")
        #expect(tree.first { $0.path == "docs/flow.excalidraw" }?.kind == .diagram)
        #expect(DocsSite.homePage(root: root, folder: "docs", tree: tree) == "docs/index.md")
        #expect(DocsSite.allPages(tree).contains { $0.path == "docs/guide/index.md" })
    }

    @Test func detectsDocusaurusAndPlainFolders() throws {
        let site = try makeSite(["website/docusaurus.config.ts": "", "website/docs/intro.md": "# Intro"])
        #expect(DocsSite.detect(root: site) == "website/docs")
        let plain = try makeSite(["documentation/a.md": "# A"])
        #expect(DocsSite.detect(root: plain) == "documentation")
        let none = try makeSite(["README.md": "# R"])
        #expect(DocsSite.detect(root: none) == nil)
    }

    @Test func normalizesFolders() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        #expect(DocsSite.normalizeFolder(" docs/ ", root: root) == "docs")
        #expect(DocsSite.normalizeFolder("/tmp/proj/a/b", root: root) == "a/b")
        #expect(DocsSite.normalizeFolder(".", root: root) == "")
        #expect(DocsSite.normalizeFolder("../x", root: root) == nil)
        #expect(DocsSite.normalizeFolder("/etc", root: root) == nil)
    }

    @Test func slugsTransliterate() throws {
        #expect(DocsSite.slug("Архитектура сервиса") == "arhitektura-servisa")
        #expect(DocsSite.slug("  API: v2!  ") == "api-v2")
        #expect(DocsSite.slug("!!!") == "page")
        let root = try makeSite(["docs/intro.md": ""])
        #expect(DocsSite.newPagePath(title: "Intro", folder: "docs", root: root) == "docs/intro-2.md")
        #expect(DocsSite.newPagePath(title: "x", folder: "docs", root: root, fileName: "notes.mdx") == "docs/notes.mdx")
    }
}

@Suite struct DocsLinkTests {
    @Test func relativeAndResolve() {
        #expect(DocsLinks.relative(from: "docs/guide", to: "docs/api/x.md") == "../api/x.md")
        #expect(DocsLinks.relative(from: "docs", to: "docs/a.md") == "a.md")
        #expect(DocsLinks.relative(from: "", to: "docs/a.md") == "docs/a.md")
        #expect(DocsLinks.resolve("../api/x.md#top", fromPage: "docs/guide/a.md") == "docs/api/x.md")
        #expect(DocsLinks.resolve("./img%20a.png", fromPage: "docs/a.md") == "docs/img a.png")
        #expect(DocsLinks.resolve("https://x.y", fromPage: "docs/a.md") == nil)
        #expect(DocsLinks.resolve("#anchor", fromPage: "docs/a.md") == nil)
        #expect(DocsLinks.resolve("../../../x.md", fromPage: "docs/a.md") == nil)
    }

    @Test func rewritesLinksIntoAMovedPage() {
        let text = "See [setup](guide/setup.md#run) and ![d](assets/d.png).\n```\n[x](guide/setup.md)\n```\n[ref]: guide/setup.md\n"
        let out = DocsLinks.rewrite(text, oldPage: "docs/index.md", newPage: "docs/index.md") {
            DocsLinks.moved($0, from: "docs/guide", to: "docs/howto")
        }
        #expect(out == "See [setup](howto/setup.md#run) and ![d](assets/d.png).\n```\n[x](guide/setup.md)\n```\n[ref]: howto/setup.md\n")
    }

    @Test func rewritesAMovedPagesOwnLinks() {
        let text = "[home](index.md) [web](https://a.b) [self](#x) ![p](assets/p.png)"
        let out = DocsLinks.rewrite(text, oldPage: "docs/a.md", newPage: "docs/sub/a.md") {
            DocsLinks.moved($0, from: "docs/a.md", to: "docs/sub/a.md")
        }
        #expect(out == "[home](../index.md) [web](https://a.b) [self](#x) ![p](../assets/p.png)")
    }

    @Test func rewritesImports() {
        let out = DocsLinks.rewrite("- @docs/a.md, and @docs/b.md.", oldPage: "CLAUDE.md", newPage: "CLAUDE.md", imports: true) {
            DocsLinks.moved($0, from: "docs/a.md", to: "docs/x/a.md")
        }
        #expect(out == "- @docs/x/a.md, and @docs/b.md.")
    }

    @Test func moveUpdatesFilesOnDisk() throws {
        let root = try makeSite([
            "docs/index.md": "[Setup](guide/setup.md)",
            "docs/guide/setup.md": "[Back](../index.md)",
            "CLAUDE.md": "@docs/guide/setup.md",
        ])
        let changed = try DocsLinks.move("docs/guide", to: "docs/how/to", root: root,
                                         files: ["docs/index.md", "docs/guide/setup.md", "CLAUDE.md"],
                                         importFiles: ["CLAUDE.md"])
        #expect(Set(changed) == ["docs/index.md", "docs/how/to/setup.md", "CLAUDE.md"])
        #expect(read(root, "docs/index.md") == "[Setup](how/to/setup.md)")
        #expect(read(root, "docs/how/to/setup.md") == "[Back](../../index.md)")
        #expect(read(root, "CLAUDE.md") == "@docs/how/to/setup.md")
        #expect(throws: (any Error).self) {
            try DocsLinks.move("docs/index.md", to: "docs/how/to/setup.md", root: root, files: [])
        }
    }
}

@Suite struct DocsSearchTests {
    @Test func findsAllWordsTitleFirst() {
        let pages: [(path: String, title: String, text: String)] = [
            ("a.md", "Установка", "Как поставить сервер.\nЗапуск сервера"),
            ("b.md", "Сервер", "Сервер и установка"),
            ("c.md", "Другое", "ничего"),
        ]
        let hits = DocsSearch.search("сервер установ", pages: pages)
        #expect(hits.map(\.path) == ["b.md", "a.md"])
        #expect(DocsSearch.search("запуск", pages: pages).first?.line == 1)
        #expect(DocsSearch.search("  ", pages: pages).isEmpty)
    }
}

@Suite struct DocsPromptTests {
    @Test func fragmentPromptNamesLines() {
        let p = DocsPrompt.make(instruction: "Make it shorter", docsFolder: "docs", page: "docs/a.md",
                                fragment: .init(firstLine: 3, lastLine: 5, text: "abc\n"))
        #expect(p.contains("lines 3–5 of `docs/a.md`"))
        #expect(p.contains("```markdown\nabc\n```"))
        #expect(p.contains("Task: Make it shorter"))
        #expect(DocsPrompt.sessionName(page: "docs/guide/setup.md", fragment: true) == "Edit: setup")
    }
}

@Suite struct DocsCompletionTests {
    @Test func detectsQueries() {
        let text = "See [setup](gu"
        let q = DocsCompletion.query(in: text, caret: (text as NSString).length)
        #expect(q?.mode == .path)
        #expect(q?.text == "gu")
        #expect(q?.range == NSRange(location: 12, length: 2))
        let wiki = "Line\nи [[уст"
        let w = DocsCompletion.query(in: wiki, caret: (wiki as NSString).length)
        #expect(w?.mode == .wiki)
        #expect(w?.text == "уст")
        #expect(w?.range == NSRange(location: 7, length: 5))
        #expect(DocsCompletion.query(in: "[a](b) c", caret: 8) == nil)
        #expect(DocsCompletion.query(in: "x\n", caret: 2) == nil)
    }

    @Test func candidatesAreRelative() {
        let pages: [(path: String, title: String)] = [("docs/guide/setup.md", "Установка"), ("docs/index.md", "Главная")]
        let wiki = DocsCompletion.Query(mode: .wiki, text: "уст", range: NSRange(location: 0, length: 5))
        #expect(DocsCompletion.candidates(wiki, pages: pages, fromPage: "docs/api/a.md").map(\.insertion)
                == ["[Установка](../guide/setup.md)"])
        let path = DocsCompletion.Query(mode: .path, text: "", range: NSRange(location: 0, length: 0))
        #expect(DocsCompletion.candidates(path, pages: pages, fromPage: "docs/index.md").map(\.insertion) == ["guide/setup.md)"])
    }
}

@Suite struct DocsFragmentTests {
    @Test func fromPreviewLines() {
        let src = "# T\n\nPara one\nstill\n\nNext\n"
        let f = DocsPrompt.fragment(source: src, firstLine: 2, lastLine: 5, selectedText: "one")
        #expect(f == .init(firstLine: 3, lastLine: 4, text: "Para one\nstill"))
        let g = DocsPrompt.fragment(source: src, firstLine: nil, lastLine: nil, selectedText: "Next")
        #expect(g == .init(firstLine: 6, lastLine: 6, text: "Next"))
    }

    @Test func fromEditorRange() {
        let src = "a\nbcd\nef"
        let f = DocsPrompt.fragment(source: src, range: NSRange(location: 3, length: 4))
        #expect(f == .init(firstLine: 2, lastLine: 3, text: "bcd\nef"))
        #expect(DocsPrompt.fragment(source: src, range: NSRange(location: 1, length: 0)) == nil)
    }
}

@Suite struct DocsDrawingTests {
    @Test func assetsFoldersAreNotSectionsAndDrawingsGetFreePaths() throws {
        let root = try makeSite([
            "docs/index.md": "# Home\n",
            "docs/assets/home-drawing.excalidraw": DocsSite.emptyDrawing,
            "docs/flow.excalidraw": DocsSite.emptyDrawing,
        ])
        let tree = DocsSite.tree(root: root, folder: "docs")
        #expect(tree.map(\.path) == ["docs/flow.excalidraw", "docs/index.md"])
        #expect(DocsSite.newDrawingPath(title: "home-drawing", folder: "docs/assets", root: root) == "docs/assets/home-drawing-2.excalidraw")
        #expect(DocsSite.newDrawingPath(title: "Request flow", folder: "docs", root: root) == "docs/request-flow.excalidraw")
        let scene = try JSONSerialization.jsonObject(with: Data(DocsSite.emptyDrawing.utf8)) as? [String: Any]
        #expect(scene?["type"] as? String == "excalidraw")
        #expect((scene?["elements"] as? [Any])?.isEmpty == true)
    }
}
