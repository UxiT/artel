import ArtelCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Projects section detail: the selected project's documentation site (docs/SPEC.md §4.9), its agent context
/// files and, from the title bar, its file tree. The project list is the tool panel (`ProjectListSidebar`).
struct ProjectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = model.docsProjectID, let project = model.project(id) {
                ProjectDocsView(project: project).id(project.id)
            } else {
                ContentUnavailableView {
                    Label(model.state.projects.isEmpty ? "No Projects" : "Select a Project", systemImage: "folder")
                } description: {
                    Text(model.state.projects.isEmpty ? "Add a project folder or drag one in from Finder." : "")
                } actions: {
                    if model.state.projects.isEmpty {
                        Button("Add Project…") { ProjectPicker.present(model) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.docsProjectID.flatMap(model.project) == nil {
                model.docsProjectID = model.focusedOrSelectedProjectID ?? model.state.projects.first?.id
            }
        }
    }
}

/// A request for the "new page / new section" sheet.
private struct NewDocsItem: Identifiable {
    let id = UUID()
    var category: Bool
    var parent: String
    /// A new `.excalidraw` drawing instead of a page.
    var diagram = false
}

/// What a project's docs view knows after a reload (read off the main thread's way of thinking: small and cheap).
private struct DocsSnapshot {
    var folder: String?
    var tree: [DocsNode] = []
    /// CLAUDE.md, context files and specs it links to outside the docs folder.
    var context: [ProjectDoc] = []
    /// Pages with their text, for search and link completion.
    var pages: [(path: String, title: String, text: String)] = []

    var pageList: [(path: String, title: String)] { pages.map { ($0.path, $0.title) } }
    var categories: [DocsNode] { DocsSite.allCategories(tree) }

    func title(of path: String) -> String? {
        pages.first { $0.path == path }?.title
    }

    func contains(_ path: String) -> Bool {
        guard let folder else { return false }
        return folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }
}

private struct ProjectDocsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var docs = DocsSnapshot()
    @State private var expandedCategories: Set<String> = []
    @State private var categoriesLoaded = false
    @AppStorage("docs.contextExpanded") private var contextExpanded = true
    @State private var newItem: NewDocsItem?
    @State private var renaming: DocsNode?
    @State private var deleting: DocsNode?
    @State private var creatingDocs = false
    @State private var newRule = false
    @FocusState private var searchFocused: Bool
    // File tree (title bar "Files").
    @State private var docIndex = DocIndex()
    @State private var listedPaths: [String] = []
    @State private var files: [FileNode] = []
    @State private var expandedFolders: Set<String> = []
    @State private var filesLoaded = false
    @State private var loadGeneration = 0
    /// The file tree's own selection: mirrors `model.docsPath`, re-applied once the row exists
    /// (List drops a selection whose row isn't in the outline yet, e.g. inside a collapsed folder).
    @State private var treeSelection: String?

    /// The page shown: the selection, else the docs home page.
    private var currentPath: String? {
        model.docsPath ?? docs.folder.flatMap { DocsSite.homePage(root: project.url, folder: $0, tree: docs.tree) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.showsProjectFiles {
                    filesHeader
                    Divider()
                    fileTree
                } else {
                    docsSidebar
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 420, maxHeight: .infinity)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .onAppear {
            reload()
            treeSelection = model.docsPath
        }
        .onChange(of: model.docsPath) { _, path in if model.showsProjectFiles { reveal(path) } }
        .onChange(of: model.showsProjectFiles) { _, files in
            if files { reloadFiles(); treeSelection = currentPath; reveal(currentPath) }
        }
        .onChange(of: model.docsVersion) { _, _ in reloadDocs() }
        .onChange(of: model.state.projects) { _, _ in
            if model.project(project.id)?.docsFolder != project.docsFolder { reloadDocs() }
        }
        .onChange(of: model.focusRequest) { _, request in
            guard request == .docsSearch else { return }
            model.focusRequest = nil
            if model.showsProjectFiles { model.showsProjectFiles = false }
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .sheet(item: $newItem) { item in
            NewDocsItemSheet(project: project, docs: docs, item: item) { path, isCategory in
                reloadDocs()
                if isCategory { expandedCategories.insert(DocsLinks.directory(of: path)) }
                expandedCategories.formUnion(ProjectFiles.ancestors(of: path))
                model.docsPath = path
                model.docsReturnPath = nil
                // A new page opens in the editor (a drawing too, when the Excalidraw editor is installed).
                if !DocsSite.isDiagram(path) || ExcalidrawAddon.shared.isInstalled {
                    model.beginEditing(.projectFile(project.id, path), saved: (try? String(contentsOf: project.url.appendingPathComponent(path), encoding: .utf8)) ?? "")
                }
            }
        }
        .sheet(item: $renaming) { node in
            RenameDocsSheet(project: project, node: node) { newPath in move(node.path, to: newPath) }
        }
        .sheet(isPresented: $creatingDocs) {
            CreateDocsSheet(project: project) { reloadDocs() }
        }
        .sheet(isPresented: $newRule) {
            NewRuleSheet(project: project) { path in
                reloadDocs()
                model.docsPath = path
                model.beginEditing(.projectFile(project.id, path), saved: (try? String(contentsOf: project.url.appendingPathComponent(path), encoding: .utf8)) ?? "")
            }
        }
        .sheet(item: Binding(get: { model.docsAgentRequest.flatMap { $0.projectID == project.id ? $0 : nil } },
                             set: { model.docsAgentRequest = $0 })) { request in
            DocsAgentSheet(project: project, request: request, pageTitle: request.page.flatMap(docs.title(of:)))
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let node = deleting { delete(node) }
                deleting = nil
            }
        } message: {
            Text(deleting?.isCategory == true ? "The section and all its pages will be moved to the Trash. Links to them from other pages will stop working."
                                             : "The file will be moved to the Trash. Links to it from other pages will stop working.")
        }
    }

    // MARK: - Documentation sidebar

    private var docsSidebar: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search documentation", text: $model.docsSearch)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onExitCommand { model.docsSearch = "" }
                Menu {
                    Button("New Page…") { newItem = NewDocsItem(category: false, parent: docs.folder ?? DocsSite.defaultFolder) }
                        .disabled(docs.folder == nil)
                    Button("New Excalidraw…") { newItem = NewDocsItem(category: false, parent: docs.folder ?? DocsSite.defaultFolder, diagram: true) }
                        .disabled(docs.folder == nil)
                    Button("New Section…") { newItem = NewDocsItem(category: true, parent: docs.folder ?? DocsSite.defaultFolder) }
                        .disabled(docs.folder == nil)
                    Divider()
                    Button("New Context Rule…") { newRule = true }
                    if docs.folder == nil {
                        Divider()
                        Button("Create Documentation…") { creatingDocs = true }
                    }
                } label: { Label("Create", systemImage: "plus").labelStyle(.iconOnly) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New page, section or context rule")
                Button { reload() } label: { Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Reload documentation from disk")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if !model.docsSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                docsList
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { currentPath }, set: { value in
            guard let value else { return }
            if value.hasPrefix("category:") {
                let path = String(value.dropFirst("category:".count))
                if expandedCategories.contains(path) { expandedCategories.remove(path) } else { expandedCategories.insert(path) }
                return
            }
            model.docsPath = value
        })
    }

    private var docsList: some View {
        List(selection: selection) {
            Section(isExpanded: $contextExpanded) {
                ForEach(docs.context) { doc in
                    ContextDocRow(doc: doc, dirty: model.isDirty(.projectFile(project.id, doc.path))).tag(doc.path)
                }
            } header: {
                HStack {
                    Text("Agent Context")
                    Spacer()
                    Button { newRule = true } label: { Label("New Rule", systemImage: "plus").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help("New rule (.claude/rules/…) — Claude Code loads it automatically")
                }
                .help("CLAUDE.md, context files (CLAUDE.local.md, AGENTS.md, .claude/rules/) and the specs CLAUDE.md links to")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { rootMenu }
            }
            Section {
                if docs.folder == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No documentation yet").foregroundStyle(.secondary)
                        Button("Create Documentation…") { creatingDocs = true }
                    }
                    .padding(.vertical, 4)
                    .selectionDisabled()
                } else if docs.tree.isEmpty {
                    Text("No pages").font(.caption).foregroundStyle(.tertiary).selectionDisabled()
                } else {
                    DocsTreeRows(nodes: docs.tree, projectID: project.id, expanded: $expandedCategories, actions: treeActions)
                }
            } header: {
                HStack {
                    Text("Documentation")
                    Spacer()
                    if let folder = docs.folder {
                        Text(folder.isEmpty ? "project root" : folder + "/").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { paths, _ in
                    guard let folder = docs.folder else { return false }
                    return moveInto(paths, folder: folder)
                }
                .contextMenu { rootMenu }
            }
        }
        .listStyle(.sidebar)
        // One menu for the whole list: a row's own menu, or the documentation menu on empty space.
        .contextMenu(forSelectionType: String.self) { items in
            if let tag = items.first {
                itemMenu(tag)
            } else {
                rootMenu
            }
        }
    }

    /// The documentation as a whole: new items at the root, the folder.
    @ViewBuilder
    private var rootMenu: some View {
        if let folder = docs.folder {
            Button("New Page…") { newItem = NewDocsItem(category: false, parent: folder) }
            Button("New Excalidraw…") { newItem = NewDocsItem(category: false, parent: folder, diagram: true) }
            Button("New Section…") { newItem = NewDocsItem(category: true, parent: folder) }
            Divider()
            Button("New Context Rule…") { newRule = true }
            Divider()
            Button("Show in Finder") { reveal(inFinder: folder) }
            Button("Choose Another Docs Folder…") { pickDocsFolder() }
        } else {
            Button("Create Documentation…") { creatingDocs = true }
            Button("Choose Docs Folder…") { pickDocsFolder() }
            Divider()
            Button("New Context Rule…") { newRule = true }
        }
    }

    /// The menu of a row, by its tag: an agent context file, a page or drawing, or a section.
    @ViewBuilder
    private func itemMenu(_ tag: String) -> some View {
        if let doc = docs.context.first(where: { $0.path == tag }) {
            contextMenu(doc)
        } else if let node = node(forTag: tag) {
            DocsNodeMenu(node: node, actions: treeActions)
        } else {
            rootMenu
        }
    }

    /// A tree node by its row tag: a page's path, a section's index page, or `category:<path>`.
    private func node(forTag tag: String) -> DocsNode? {
        func find(_ nodes: [DocsNode]) -> DocsNode? {
            for n in nodes {
                if n.path == tag || n.indexPath == tag || "category:" + n.path == tag { return n }
                if let hit = find(n.children ?? []) { return hit }
            }
            return nil
        }
        return find(docs.tree)
    }

    private var treeActions: DocsTreeActions {
        DocsTreeActions(
            newPage: { parent in newItem = NewDocsItem(category: false, parent: parent) },
            newDiagram: { parent in newItem = NewDocsItem(category: false, parent: parent, diagram: true) },
            newCategory: { parent in newItem = NewDocsItem(category: true, parent: parent) },
            rename: { renaming = $0 },
            delete: { deleting = $0 },
            moveTargets: { node in moveTargets(for: node) },
            move: { node, folder in moveInto([node.path], folder: folder) },
            drop: { paths, folder in moveInto(paths, folder: folder) },
            reveal: { reveal(inFinder: $0) },
            openInEditor: { path in
                if let url = ProjectDocs.url(path, root: project.url) {
                    model.openInEditor(projectID: project.id, root: project.url, files: [url])
                }
            },
            askAgent: { path in model.docsAgentRequest = DocsAgentRequest(projectID: project.id, page: path, fragment: nil) })
    }

    private var searchResults: some View {
        let hits = DocsSearch.search(model.docsSearch, pages: docs.pages)
        return List(selection: Binding(get: { currentPath }, set: { if let p = $0 { model.docsPath = p } })) {
            Section("Results: \(hits.count)") {
                ForEach(hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(hit.title).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(hit.matches)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(hit.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .tag(hit.path)
                }
                if hits.isEmpty {
                    Text("No results").font(.caption).foregroundStyle(.tertiary).selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { items in
            if let tag = items.first { itemMenu(tag) } else { rootMenu }
        }
    }

    @ViewBuilder
    private func contextMenu(_ doc: ProjectDoc) -> some View {
        if doc.kind == .spec && !doc.linked {
            Button("Link in CLAUDE.md") { linkIntoClaudeMD(doc.path) }
        }
        if doc.exists {
            Button("Show in Finder") { reveal(inFinder: doc.path) }
            Button("Open in Code Editor") {
                if let url = ProjectDocs.url(doc.path, root: project.url) {
                    model.openInEditor(projectID: project.id, root: project.url, files: [url])
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let path = currentPath {
            let url = ProjectDocs.url(path, root: project.url) ?? project.url.appendingPathComponent(path)
            if DocsSite.isDiagram(path) {
                DiagramPageView(project: project, path: path, title: docs.title(of: path)).id(project.id.uuidString + path)
            } else if DocsSite.isPage(path) || docs.context.contains(where: { $0.path == path }) {
                let isContext = docs.context.contains { $0.path == path }
                DocPageView(project: project, path: path,
                            role: isContext ? .context : docs.contains(path) ? .page : .file,
                            exists: FileManager.default.fileExists(atPath: url.path),
                            completion: LinkCompletionSource(page: path, pages: docs.pageList),
                            highlight: model.docsSearch.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.docsSearch,
                            anchor: pendingAnchor,
                            openLink: { open($0, from: path) })
                    .id(project.id.uuidString + path)
            } else {
                FilePreviewPane(project: project, path: path)
            }
        } else if docs.folder == nil {
            NoDocsView(project: project, create: { creatingDocs = true }, pick: pickDocsFolder)
        } else {
            Text("Select a page").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading

    private func reload() {
        reloadDocs()
        if model.showsProjectFiles { reloadFiles() }
    }

    /// Re-reads the documentation tree, the context files and page texts.
    private func reloadDocs() {
        let current = model.project(project.id) ?? project
        let folder = model.docsFolder(for: current)
        var snapshot = DocsSnapshot(folder: folder)
        if let folder {
            snapshot.tree = DocsSite.tree(root: project.url, folder: folder)
            snapshot.pages = DocsSite.allPages(snapshot.tree).filter { $0.kind == .page }.map { node in
                (node.path, node.title, (try? String(contentsOf: project.url.appendingPathComponent(node.path), encoding: .utf8)) ?? "")
            }
        }
        snapshot.context = ProjectDocs.discover(root: project.url).filter { $0.kind != .spec || !snapshot.contains($0.path) }
        docs = snapshot
        docIndex = DocIndex(ProjectDocs.discover(root: project.url))
        if !categoriesLoaded {
            categoriesLoaded = true
            expandedCategories = Set(snapshot.categories.map(\.path))
        }
        if let path = model.docsPath { expandedCategories.formUnion(ProjectFiles.ancestors(of: path)) }
    }

    /// Re-reads the project's file list (git runs off the main thread; a stale result is dropped).
    private func reloadFiles() {
        let root = project.url
        let git = model.git?.executable
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            let paths = await Task.detached { ProjectFiles.list(root: root, git: git) }.value
            guard generation == loadGeneration else { return }
            listedPaths = paths
            files = ProjectFiles.tree(paths + Array(docIndex.byPath.keys))
            if !filesLoaded {
                filesLoaded = true
                if let path = currentPath { expandedFolders.formUnion(ProjectFiles.ancestors(of: path)) }
                reselectLater()
            }
        }
    }

    // MARK: - Moving, deleting

    /// Folders a node can move into: the docs root and every section that isn't the node itself or inside it.
    private func moveTargets(for node: DocsNode) -> [(path: String, title: String)] {
        guard let folder = docs.folder else { return [] }
        let current = DocsLinks.directory(of: node.path)
        var out: [(String, String)] = []
        if current != folder { out.append((folder, "Documentation (Root)")) }
        for c in docs.categories where c.path != node.path && !c.path.hasPrefix(node.path + "/") && c.path != current {
            let depth = c.path.split(separator: "/").count - folder.split(separator: "/").count - 1
            out.append((c.path, String(repeating: "   ", count: max(0, depth)) + c.title))
        }
        return out
    }

    @discardableResult
    private func moveInto(_ paths: [String], folder: String) -> Bool {
        var moved = false
        for path in paths where path != folder && !folder.hasPrefix(path + "/") && DocsLinks.directory(of: path) != folder {
            let name = (path as NSString).lastPathComponent
            moved = move(path, to: folder.isEmpty ? name : folder + "/" + name) || moved
        }
        return moved
    }

    /// Moves or renames a page or section and fixes the links to it (and its own) across the docs and CLAUDE.md.
    @discardableResult
    private func move(_ from: String, to: String) -> Bool {
        guard from != to else { return false }
        if !model.dirtyDocuments(projectID: project.id, under: from).isEmpty {
            model.errorMessage = "Save your changes to the pages you are moving first."
            return false
        }
        let files = docs.pages.map(\.path) + docs.context.filter(\.exists).map(\.path)
        do {
            try DocsLinks.move(from, to: to, root: project.url, files: Array(Set(files)),
                               importFiles: Set(docs.context.map(\.path)))
        } catch {
            model.errorMessage = "Couldn't move \(from): \(error.localizedDescription)"
            return false
        }
        model.moveDrafts(projectID: project.id, from: from, to: to)
        if expandedCategories.contains(from) { expandedCategories.insert(to) }
        reloadDocs()
        return true
    }

    private func delete(_ node: DocsNode) {
        do {
            try FileManager.default.trashItem(at: project.url.appendingPathComponent(node.path), resultingItemURL: nil)
        } catch {
            model.errorMessage = "Couldn't delete \(node.path): \(error.localizedDescription)"
            return
        }
        model.moveDrafts(projectID: project.id, from: node.path, to: nil)
        reloadDocs()
    }

    // MARK: - Links

    /// A link clicked in a page: another page opens here, a URL in its app, a project file in the code editor.
    private func open(_ link: String, from page: String) {
        if let url = URL(string: link), let scheme = url.scheme, !["artel-doc", ArtelResourceHandler.scheme].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        var anchor: String?
        let target: String?
        if link.hasPrefix("artel-doc:") {
            let raw = String(link.dropFirst("artel-doc:".count))
            target = raw.removingPercentEncoding ?? raw
        } else if link.hasPrefix(ArtelResourceHandler.scheme + "://local/root/") {
            let raw = String(link.dropFirst((ArtelResourceHandler.scheme + "://local/root/").count))
            target = (raw.split(separator: "#").first.map(String.init) ?? raw).removingPercentEncoding
        } else {
            if let hash = link.firstIndex(of: "#") { anchor = String(link[link.index(after: hash)...]) }
            target = DocsLinks.resolve(link, fromPage: page)
        }
        guard let target else { return }
        let fm = FileManager.default
        // Docusaurus links may drop the extension: `./setup` → setup.md, `./guide` → guide/index.md.
        let candidates = [target] + ["md", "mdx"].map { target + "." + $0 } + ["index.md", "README.md"].map { target + "/" + $0 }
        guard let found = candidates.first(where: { p in
            var dir: ObjCBool = false
            return fm.fileExists(atPath: project.url.appendingPathComponent(p).path, isDirectory: &dir) && !dir.boolValue
        }) else {
            model.errorMessage = "File \(target) not found"
            return
        }
        if DocsSite.isPage(found) || DocsSite.isDiagram(found) || docs.context.contains(where: { $0.path == found }) {
            pendingAnchor = anchor
            // A drawing opened from a page comes back to it on "Done".
            model.docsReturnPath = DocsSite.isDiagram(found) && !DocsSite.isDiagram(page) ? page : nil
            model.docsPath = found
        } else if let url = ProjectDocs.url(found, root: project.url) {
            let textLike = ["txt", "swift", "go", "py", "ts", "js", "json", "yaml", "yml", "toml", "rs", "kt", "java", "sh"]
            if textLike.contains(url.pathExtension.lowercased()) {
                model.openInEditor(projectID: project.id, root: project.url, files: [url])
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @State private var pendingAnchor: String?

    private func linkIntoClaudeMD(_ path: String) {
        let url = project.url.appendingPathComponent(ProjectDocs.claudeMD)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try ProjectDocs.link(path, into: text).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = "Couldn't update CLAUDE.md: \(error.localizedDescription)"
        }
        reloadDocs()
    }

    private func reveal(inFinder path: String) {
        let url = path.isEmpty ? project.url : project.url.appendingPathComponent(path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Points the project at an existing folder as its documentation (kept in Artel's own state only).
    private func pickDocsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = project.url
        panel.prompt = "Choose"
        panel.message = "Documentation folder inside the project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let folder = DocsSite.normalizeFolder(url.path, root: project.url) else {
            model.errorMessage = "The documentation folder must be inside the project."
            return
        }
        model.setDocsFolder(folder, for: project.id)
        model.docsPath = nil
        reloadDocs()
    }

    // MARK: - File tree

    private var filesHeader: some View {
        HStack(spacing: 6) {
            Text("Project Files").font(.callout.weight(.medium))
            Spacer(minLength: 0)
            Button { expandedFolders = [] } label: {
                Label("Collapse All Folders", systemImage: "arrow.down.right.and.arrow.up.left").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Collapse all folders")
            Button { reload() } label: { Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Reload")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var fileTree: some View {
        FileTreeView(nodes: files, docs: docIndex,
                     selection: Binding(get: { treeSelection }, set: { p in
                         guard let p else { return }
                         treeSelection = p
                         model.docsPath = p
                     }),
                     expanded: $expandedFolders,
                     menu: { AnyView(fileMenu($0)) })
            .help("Project files, excluding those ignored by .gitignore. Agent documents (CLAUDE.md, specs, context) are marked with a badge.")
    }

    @ViewBuilder
    private func fileMenu(_ path: String) -> some View {
        if DocsSite.isPage(path), docIndex.byPath[path] == nil {
            Button("Link in CLAUDE.md as Spec") { linkIntoClaudeMD(path) }
        }
        if let url = ProjectDocs.url(path, root: project.url) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open in Code Editor") { model.openInEditor(projectID: project.id, root: project.url, files: [url]) }
        }
    }

    /// Expands the folders down to `path` so the selection is visible in the file tree.
    private func reveal(_ path: String?) {
        guard let path else { treeSelection = nil; return }
        let closed = ProjectFiles.ancestors(of: path).filter { !expandedFolders.contains($0) }
        expandedFolders.formUnion(closed)
        if closed.isEmpty { treeSelection = path } else { reselectLater() }
    }

    /// Selects the current path in the tree after the outline has added the rows just expanded or loaded.
    private func reselectLater() {
        treeSelection = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            treeSelection = currentPath
        }
    }
}

// MARK: - Tree

/// What the rows of the documentation tree can ask for.
private struct DocsTreeActions {
    var newPage: (String) -> Void
    var newDiagram: (String) -> Void
    var newCategory: (String) -> Void
    var rename: (DocsNode) -> Void
    var delete: (DocsNode) -> Void
    var moveTargets: (DocsNode) -> [(path: String, title: String)]
    var move: (DocsNode, String) -> Void
    var drop: ([String], String) -> Bool
    var reveal: (String) -> Void
    var openInEditor: (String) -> Void
    var askAgent: (String) -> Void
}

/// Sections are disclosure groups (their index page opens on click), pages are rows. Rows drag onto sections and
/// onto the "Documentation" header to move.
private struct DocsTreeRows: View {
    @Environment(AppModel.self) private var model
    let nodes: [DocsNode]
    let projectID: UUID
    @Binding var expanded: Set<String>
    let actions: DocsTreeActions

    var body: some View {
        ForEach(nodes) { node in
            if node.isCategory {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(node.path) },
                    set: { if $0 { expanded.insert(node.path) } else { expanded.remove(node.path) } }
                )) {
                    DocsTreeRows(nodes: node.children ?? [], projectID: projectID, expanded: $expanded, actions: actions)
                } label: {
                    row(node)
                        .tag(node.indexPath ?? "category:" + node.path)
                        .dropDestination(for: String.self) { (paths: [String], _: CGPoint) -> Bool in actions.drop(paths, node.path) }
                }
            } else {
                row(node).tag(node.path)
            }
        }
    }

    private func row(_ node: DocsNode) -> some View {
        let page = node.isCategory ? node.indexPath : node.path
        let dirty = page.map { model.isDirty(.projectFile(projectID, $0)) } ?? false
        return HStack(spacing: 6) {
            Image(systemName: node.kind == .category ? "folder" : node.kind == .diagram ? "scribble.variable" : "doc.text")
                .foregroundStyle(.secondary)
            Text(node.title).lineLimit(1)
            Spacer(minLength: 0)
            if dirty { UnsavedDot() }
        }
        .help(node.path)
        .draggable(node.path)
    }
}

/// The context menu of a page, drawing or section in the documentation tree.
private struct DocsNodeMenu: View {
    let node: DocsNode
    let actions: DocsTreeActions

    var body: some View {
        let folder = node.isCategory ? node.path : DocsLinks.directory(of: node.path)
        Button("New Page…") { actions.newPage(folder) }
        Button("New Excalidraw…") { actions.newDiagram(folder) }
        Button("New Section…") { actions.newCategory(folder) }
        Divider()
        if node.kind == .page || node.indexPath != nil {
            Button("Ask Agent…") { actions.askAgent(node.indexPath ?? node.path) }
        }
        Button("Rename…") { actions.rename(node) }
        let targets = actions.moveTargets(node)
        if !targets.isEmpty {
            Menu("Move To") {
                ForEach(targets, id: \.path) { t in Button(t.title) { actions.move(node, t.path) } }
            }
        }
        Divider()
        Button("Show in Finder") { actions.reveal(node.path) }
        if !node.isCategory { Button("Open in Code Editor") { actions.openInEditor(node.path) } }
        Divider()
        Button("Delete…", role: .destructive) { actions.delete(node) }
    }
}

private struct ContextDocRow: View {
    let doc: ProjectDoc
    let dirty: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: doc.kind == .description ? "doc.richtext" : doc.kind == .spec ? "doc.text" : "brain")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name).lineLimit(1)
                if doc.path != doc.name {
                    Text((doc.path as NSString).deletingLastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if dirty { UnsavedDot() }
            if !doc.exists {
                Text("missing").font(.caption2).foregroundStyle(.red)
                    .help("CLAUDE.md links to a file that doesn't exist")
            } else if doc.kind == .spec && !doc.linked {
                Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                    .help("Not linked in CLAUDE.md — the agent won't see it on its own. Right-click → “Link in CLAUDE.md”.")
            }
        }
    }
}

// MARK: - Page

/// One markdown document: the rendered page, the source editor on "Edit". Changes are saved explicitly.
private struct DocPageView: View {
    enum Role { case page, context, file }

    @Environment(AppModel.self) private var model
    let project: Project
    let path: String
    let role: Role
    let exists: Bool
    let completion: LinkCompletionSource
    let highlight: String?
    let anchor: String?
    let openLink: (String) -> Void

    @State private var disk = ""
    @State private var loaded = false
    @State private var modified: Date?
    @State private var watcher: FileWatcher?
    @State private var insertion: String?
    @State private var editorSelection = NSRange(location: 0, length: 0)

    private var key: DocumentKey { .projectFile(project.id, path) }
    private var url: URL? { ProjectDocs.url(path, root: project.url) }
    private var dir: String { DocsLinks.directory(of: path) }
    private var isClaudeMD: Bool { path == ProjectDocs.claudeMD }

    var body: some View {
        let editing = model.isEditing(key)
        let text = model.draftText(key) ?? disk
        let invalid = isClaudeMD && editing && !ProjectValidator.hasDescription(text)
        VStack(spacing: 0) {
            header(editing: editing, invalid: invalid, text: text)
            if invalid {
                Label("CLAUDE.md needs a filled-in “## Description” section — the file can't be saved without it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if let session = model.docsAgentSession(projectID: project.id, page: path) {
                AgentSessionBar(session: session)
            }
            Divider()
            if !exists && !loaded && !editing {
                VStack(spacing: 10) {
                    Text("\(path) doesn't exist").foregroundStyle(.secondary)
                    Button("Create") { create() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownPane(
                    text: Binding(get: { model.draftText(key) ?? disk }, set: { model.updateDraft(key, text: $0) }),
                    editing: editing,
                    source: MarkdownPreviewSource(
                        root: project.url, baseDir: dir, documentID: project.id.uuidString + path,
                        linkReferences: role == .context, mdx: (path as NSString).pathExtension.lowercased() == "mdx",
                        highlight: highlight, anchor: anchor, emptyText: "The page is empty — click Edit (⌘E)",
                        openLink: openLink,
                        askAgent: { fragment in
                            model.docsAgentRequest = DocsAgentRequest(projectID: project.id, page: path, fragment: fragment)
                        }),
                    insertion: $insertion,
                    referencesForDrop: { references($0) },
                    pasteImage: role == .context ? nil : { saveImage($0, name: nil) },
                    completion: role == .context ? nil : completion,
                    onExit: { model.finishEditing(key) },
                    onSelection: { editorSelection = $0 })
            }
        }
        .onAppear {
            load()
            // Edits made elsewhere (the agent, another editor) show up live while there are no local changes.
            if let url { watcher = FileWatcher(url: url) { reloadIfChangedOutside() } }
        }
        .onDisappear { watcher = nil }
    }

    private func header(editing: Bool, invalid: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title(text)).font(.headline).lineLimit(1)
                    if model.isDirty(key) { UnsavedDot() }
                }
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if editing {
                if role != .context {
                    Menu {
                        ForEach(completion.pages.filter { $0.path != path }, id: \.path) { p in
                            Button(p.title) { insertion = "[\(p.title)](\(DocsLinks.target(p.path, fromPage: path)))" }
                        }
                    } label: { Label("Link", systemImage: "link") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Insert a link to a page (or type [[ in the text)")
                    Button { insertImage() } label: { Label("Image", systemImage: "photo") }
                        .help("Insert an image: the file is copied to assets/ next to the page. You can also paste from the clipboard (⌘V)")
                    if ExcalidrawAddon.shared.isInstalled {
                        Button { draw(text) } label: { Label("Draw", systemImage: "scribble.variable") }
                            .help("Insert a new Excalidraw drawing at the cursor and open it for editing")
                    }
                }
                if editorSelection.length > 0 {
                    Button { askAboutSelection(text) } label: { Label("Agent", systemImage: "sparkles") }
                        .help("Ask the agent to change the selected text")
                }
            } else {
                Button { model.docsAgentRequest = DocsAgentRequest(projectID: project.id, page: path, fragment: nil) } label: {
                    Label("Agent", systemImage: "sparkles")
                }
                .help("Ask the agent to extend or rewrite the page. For a fragment, select text and open the context menu")
            }
            MarkdownEditButton(editing: editing, dirty: model.isDirty(key), canSave: !invalid,
                               edit: { model.beginEditing(key, saved: disk) },
                               done: { model.finishEditing(key) },
                               save: { model.saveDraft(key) },
                               discard: { model.discardDraft(key) })
            Menu {
                if let url {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Open in Code Editor") { model.openInEditor(projectID: project.id, root: project.url, files: [url]) }
                }
            } label: { Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func title(_ text: String) -> String {
        DocsSite.pageTitle(front: FrontMatter.parse(text), fileName: (path as NSString).lastPathComponent)
    }

    private func askAboutSelection(_ text: String) {
        guard let fragment = DocsPrompt.fragment(source: text, range: editorSelection) else { return }
        model.docsAgentRequest = DocsAgentRequest(projectID: project.id, page: path, fragment: fragment)
    }

    private func reloadIfChangedOutside() {
        guard let url, let m = mtime(url), m != modified else { return }
        load()
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func load() {
        guard let url, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        disk = content
        modified = mtime(url)
        loaded = true
        model.reloadDraft(key, saved: content)
    }

    private func create() {
        let template = isClaudeMD ? ProjectValidator.claudeMDTemplate(projectName: project.name)
            : DocsSite.newPageText(title: DocsSite.prettify(((path as NSString).lastPathComponent as NSString).deletingPathExtension))
        model.beginEditing(key, saved: "", text: template)
    }

    // MARK: Files into the page

    /// Dropped files: project files become relative links (`@path` in context files), others are copied to assets/.
    private func references(_ urls: [URL]) -> [String] {
        let root = project.url.resolvingSymlinksInPath().path + "/"
        return urls.compactMap { url in
            guard url.isFileURL else { return url.absoluteString }
            let p = url.resolvingSymlinksInPath().path
            if role == .context {
                return p.hasPrefix(root) ? "@" + p.dropFirst(root.count) : url.absoluteString
            }
            let image = Self.imageExtensions.contains(url.pathExtension.lowercased())
            if p.hasPrefix(root) {
                let rel = String(p.dropFirst(root.count))
                let target = DocsLinks.target(rel, fromPage: path)
                let name = DocsSite.isPage(rel) ? (completion.pages.first { $0.path == rel }?.title ?? url.deletingPathExtension().lastPathComponent)
                    : url.lastPathComponent
                return image || DocsSite.isDiagram(rel) ? "![\(name)](\(target))" : "[\(name)](\(target))"
            }
            guard let copied = copyToAssets(url) else { return nil }
            return image || DocsSite.isDiagram(url.lastPathComponent)
                ? "![\(url.deletingPathExtension().lastPathComponent)](\(copied))" : "[\(url.lastPathComponent)](\(copied))"
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "tiff"]

    private var assetsDir: URL {
        project.url.appendingPathComponent(dir.isEmpty ? "assets" : dir + "/assets", isDirectory: true)
    }

    /// Copies a file into `assets/` next to the page; returns the link target.
    private func copyToAssets(_ source: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            let dest = unique(assetsDir.appendingPathComponent(source.lastPathComponent))
            try fm.copyItem(at: source, to: dest)
            return "assets/" + dest.lastPathComponent
        } catch {
            model.errorMessage = "Couldn't copy \(source.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// A pasted image saved as assets/image-<time>.png; returns the markdown to insert.
    private func saveImage(_ data: Data, name: String?) -> String? {
        do {
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
                .dateSeparator(.dash).timeSeparator(.omitted)).replacingOccurrences(of: "T", with: "-")
            let dest = unique(assetsDir.appendingPathComponent("image-\(stamp).png"))
            try data.write(to: dest)
            return "![](assets/\(dest.lastPathComponent))"
        } catch {
            model.errorMessage = "Couldn't save the image: \(error.localizedDescription)"
            return nil
        }
    }

    private func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// "Draw": a new drawing in assets/ next to the page, embedded at the cursor; the drawing opens in the editor
    /// and "Done" there comes back here.
    private func draw(_ text: String) {
        let pageName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = dir.isEmpty ? "assets" : dir + "/assets"
        let drawing = DocsSite.newDrawingPath(title: pageName + "-drawing", folder: folder, root: project.url)
        do {
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            try DocsSite.emptyDrawing.write(to: project.url.appendingPathComponent(drawing), atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = "Couldn't create the drawing: \(error.localizedDescription)"
            return
        }
        let ns = text as NSString
        let at = min(editorSelection.location + editorSelection.length, ns.length)
        let embed = "![](\(DocsLinks.target(drawing, fromPage: path)))"
        let before = at > 0 && ns.character(at: at - 1) != 10 ? "\n\n" : ""
        model.updateDraft(key, text: ns.replacingCharacters(in: NSRange(location: at, length: 0), with: before + embed + "\n"))
        model.docsReturnPath = path
        model.docsPath = drawing
        model.beginEditing(.projectFile(project.id, drawing), saved: DocsSite.emptyDrawing)
    }

    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // Images and Excalidraw drawings (embedded the same way).
        panel.allowedContentTypes = [.image] + [UTType(filenameExtension: DocsSite.diagramExtension)].compactMap { $0 }
        panel.prompt = "Insert"
        guard panel.runModal() == .OK else { return }
        insertion = references(panel.urls).joined(separator: "\n")
    }
}

/// "The agent is working on this page" under the page header, while its session lives.
private struct AgentSessionBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionRecord

    var body: some View {
        let activity = model.status(session.id).activity
        HStack(spacing: 8) {
            Image(systemName: activity.symbol).foregroundStyle(activity.color)
            Text("Agent “\(session.name)”: \(activity.title.lowercased())").font(.caption)
            Text("— page changes will appear here automatically").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Open Session") { model.focus(session.id) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(activity.color.opacity(0.1))
    }
}

/// An `.excalidraw` drawing: rendered, and edited in Excalidraw's own editor when the Excalidraw download is
/// installed. Saving is explicit, like pages; "Done" returns to the page the drawing was opened from.
private struct DiagramPageView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let path: String
    let title: String?
    @State private var version = 0
    @State private var disk = ""
    @State private var watcher: FileWatcher?
    @State private var addon = ExcalidrawAddon.shared

    private var key: DocumentKey { .projectFile(project.id, path) }
    private var url: URL? { ProjectDocs.url(path, root: project.url) }

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let editing = model.isEditing(key) && addon.isInstalled
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let back = model.docsReturnPath {
                    Button { goBack(to: back) } label: { Label("Back", systemImage: "chevron.left") }
                        .help("Back to \(back)")
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title ?? DocsSite.prettify((name as NSString).deletingPathExtension)).font(.headline)
                        if model.isDirty(key) { UnsavedDot() }
                    }
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if addon.isInstalled {
                    MarkdownEditButton(editing: editing, dirty: model.isDirty(key), doneShortcut: true,
                                       edit: { model.beginEditing(key, saved: disk) },
                                       done: finish,
                                       save: { model.saveDraft(key) },
                                       discard: { model.discardDraft(key) })
                } else {
                    ExcalidrawAddonRow(compact: true)
                }
                Menu {
                    if let url {
                        Button("Open in App") { NSWorkspace.shared.open(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if editing {
                ExcalidrawEditorView(json: model.draftText(key) ?? disk, documentID: project.id.uuidString + path,
                                     onChange: { model.updateDraft(key, text: $0) })
            } else {
                MarkdownWebView(options: MarkdownRenderOptions(markdown: "![\(name)](\(enc)?v=\(version))",
                                                               baseDir: DocsLinks.directory(of: path)),
                                root: project.url, documentID: project.id.uuidString + path, onLink: { _ in })
            }
        }
        .onAppear {
            load()
            if let url { watcher = FileWatcher(url: url) { load(); version += 1 } }
        }
        .onDisappear { watcher = nil }
    }

    private func load() {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        disk = text
        model.reloadDraft(key, saved: text)
    }

    private func finish() {
        model.finishEditing(key)
        guard !model.isEditing(key) else { return }
        if let back = model.docsReturnPath { goBack(to: back) }
    }

    private func goBack(to page: String) {
        model.docsReturnPath = nil
        model.docsPath = page
    }
}

/// The project has no documentation folder yet.
private struct NoDocsView: View {
    let project: Project
    let create: () -> Void
    let pick: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Documentation Yet", systemImage: "book.pages")
        } description: {
            Text("Documentation pages are Docusaurus-compatible markdown files in a project folder (docs/ by default), with Mermaid and Excalidraw diagrams, math and admonitions. Write them yourself or hand them to an agent.")
        } actions: {
            Button("Create Documentation…", action: create).buttonStyle(.glassProminent)
            Button("Choose Existing Folder…", action: pick)
        }
    }
}

// MARK: - Sheets

/// Creates the documentation folder: `docs/` unless the operator picks another one inside the project.
private struct CreateDocsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let created: () -> Void
    @State private var folder = DocsSite.defaultFolder

    var body: some View {
        let normalized = DocsSite.normalizeFolder(folder, root: project.url)
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Documentation").font(.title3.bold())
            Text("Where should the pages live? The folder is created in the project with a starter index.md page.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("docs", text: $folder)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { if let normalized { create(normalized) } }
                Button("Choose…") { choose() }
            }
            Text(normalized.map { "\(project.name)/\($0.isEmpty ? "" : $0 + "/")index.md" } ?? "The folder must be inside the project")
                .font(.caption.monospaced()).foregroundStyle(normalized == nil ? Color.red : .secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { if let normalized { create(normalized) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalized == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = project.url
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url, let f = DocsSite.normalizeFolder(url.path, root: project.url) {
            folder = f
        }
    }

    private func create(_ folder: String) {
        guard model.createDocs(project: project, folder: folder) != nil else { return }
        created()
        dismiss()
    }
}

/// New page or section: a title, the folder, and the file name derived from the title (editable).
private struct NewDocsItemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let docs: DocsSnapshot
    let item: NewDocsItem
    let created: (String, Bool) -> Void
    @State private var title = ""
    @State private var fileName = ""
    @State private var fileNameEdited = false
    @State private var parent = ""

    var body: some View {
        let path = targetPath
        VStack(alignment: .leading, spacing: 12) {
            Text(item.category ? "New Section" : item.diagram ? "New Excalidraw" : "New Page").font(.title3.bold())
            Form {
                TextField("Title", text: $title, prompt: Text(item.category ? "Guide" : item.diagram ? "Request flow" : "Installation"))
                    .onChange(of: title) { _, t in if !fileNameEdited { fileName = t.isEmpty ? "" : DocsSite.slug(t) } }
                TextField(item.category ? "Folder" : "File", text: Binding(get: { fileName }, set: { fileName = $0; fileNameEdited = true }),
                          prompt: Text(item.category ? "guide" : item.diagram ? "request-flow" : "setup"))
                    .font(.body.monospaced())
                Picker("Location", selection: $parent) {
                    if let folder = docs.folder { Text("Documentation (Root)").tag(folder) }
                    ForEach(docs.categories) { c in Text(c.title + "  —  " + c.path).tag(c.path) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text(path.map { item.category ? "\($0)/index.md" : $0 } ?? " ").font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || path == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { parent = item.parent }
    }

    private var targetPath: String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let name = fileName.trimmingCharacters(in: .whitespaces)
        if item.category { return DocsSite.newFolderPath(title: name.isEmpty ? t : name, folder: parent, root: project.url) }
        if item.diagram { return DocsSite.newDrawingPath(title: name.isEmpty ? t : name, folder: parent, root: project.url) }
        return DocsSite.newPagePath(title: t, folder: parent, root: project.url, fileName: name.isEmpty ? nil : name)
    }

    private func create() {
        guard let path = targetPath else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        do {
            if item.category {
                try DocsSite.createCategory(at: path, label: t, root: project.url)
                let index = path + "/index.md"
                try DocsSite.newPageText(title: t).write(to: project.url.appendingPathComponent(index), atomically: true, encoding: .utf8)
                created(index, true)
            } else {
                let url = project.url.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (item.diagram ? DocsSite.emptyDrawing : DocsSite.newPageText(title: t))
                    .write(to: url, atomically: true, encoding: .utf8)
                created(path, false)
            }
            dismiss()
        } catch {
            model.errorMessage = "Couldn't create: \(error.localizedDescription)"
        }
    }
}

/// Renames a page's file or a section's folder (links to it are fixed), and a section's label.
private struct RenameDocsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let node: DocsNode
    let rename: (String) -> Bool
    @State private var name = ""
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(node.isCategory ? "Rename Section" : "Rename File").font(.title3.bold())
            Form {
                if node.isCategory {
                    TextField("Label", text: $label)
                }
                TextField(node.isCategory ? "Folder" : "File", text: $name).font(.body.monospaced())
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Links to \(node.isCategory ? "the section's pages" : "this page") from other pages and from CLAUDE.md will be updated.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            let file = (node.path as NSString).lastPathComponent
            name = node.isCategory ? file : (file as NSString).deletingPathExtension
            label = node.title
        }
    }

    private var ext: String { (node.path as NSString).pathExtension }

    private var newName: String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), !n.hasPrefix(".") else { return nil }
        return node.isCategory || ext.isEmpty ? n : n + "." + ext
    }

    private func apply() {
        guard let newName else { return }
        let dir = DocsLinks.directory(of: node.path)
        let target = dir.isEmpty ? newName : dir + "/" + newName
        if target != node.path, !rename(target) { return }
        if node.isCategory {
            let l = label.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty && l != node.title { setLabel(l, folder: target) }
        }
        model.docsVersion += 1
        dismiss()
    }

    /// Writes the label into `_category_.json`, keeping its other keys.
    private func setLabel(_ label: String, folder: String) {
        let url = project.url.appendingPathComponent(folder).appendingPathComponent("_category_.json")
        var obj = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        obj["label"] = label
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// New `.claude/rules/<name>.md` (Claude Code loads rules on its own).
private struct NewRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let created: (String) -> Void
    @State private var name = ""

    var body: some View {
        let path = ProjectDocs.newPath(kind: .context, name: name)
        VStack(alignment: .leading, spacing: 12) {
            Text("New Context Rule").font(.title3.bold())
            TextField("style, testing…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let path { create(path) } }
            Text(path.map { "File: \($0)" } ?? " ").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Claude Code loads .claude/rules/*.md automatically.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { if let path { create(path) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create(_ path: String) {
        guard let url = ProjectDocs.url(path, root: project.url) else { return }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "# \(url.deletingPathExtension().lastPathComponent)\n\n".write(to: url, atomically: true, encoding: .utf8)
            }
            created(path)
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// "Ask the agent": an instruction for a page, a fragment of it, or the docs as a whole. Starts a session in the
/// project checkout; the page shows the agent's edits as they land.
private struct DocsAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let request: DocsAgentRequest
    let pageTitle: String?
    @State private var instruction = ""
    @State private var agentID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.fragment == nil ? "Agent: Documentation Page" : "Agent: Page Fragment").font(.title3.bold())
            if let page = request.page {
                Label { Text(pageTitle.map { "\($0) — \(page)" } ?? page).lineLimit(1).truncationMode(.middle) } icon: {
                    Image(systemName: "doc.text")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            if let fragment = request.fragment {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fragment.firstLine == fragment.lastLine ? "Line \(fragment.firstLine)" : "Lines \(fragment.firstLine)–\(fragment.lastLine)")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(fragment.text).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("What should it do?").font(.callout.weight(.medium))
            TextEditor(text: $instruction)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            if model.enabledAgents.count > 1 {
                Picker("Agent", selection: $agentID) {
                    ForEach(model.enabledAgents, id: \.agentID) { Text($0.displayName).tag($0.agentID) }
                }
                .fixedSize()
            }
            Text("The session starts in the project folder (not in a worktree) and appears in Workspace. Unsaved page changes are saved before launch.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Launch") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isReady)
                    .help("Launch the agent (⌘⏎)")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { agentID = model.state.settings.effectiveDefaultAgentID }
    }

    private func start() {
        model.startDocsAgent(request, instruction: instruction, agentID: agentID)
        dismiss()
    }
}

extension ProjectDoc.Kind: Identifiable {
    public var id: String { rawValue }
}
