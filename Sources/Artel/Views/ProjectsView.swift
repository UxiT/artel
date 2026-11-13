import ArtelCore
import AppKit
import SwiftUI

/// Projects section detail: the selected project's files and documents with a markdown editor.
/// The project list is the window sidebar (`ProjectListSidebar`).
struct ProjectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = model.docsProjectID, let project = model.project(id) {
                ProjectDocsView(project: project).id(project.id)
            } else {
                ContentUnavailableView {
                    Label(model.state.projects.isEmpty ? "Нет проектов" : "Выберите проект", systemImage: "folder")
                } description: {
                    Text(model.state.projects.isEmpty ? "Добавьте папку проекта или перетащите её из Finder." : "")
                } actions: {
                    if model.state.projects.isEmpty {
                        Button("Добавить проект…") { ProjectPicker.present(model) }
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

private struct ProjectDocsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var docs: [ProjectDoc] = []
    @State private var docIndex = DocIndex()
    /// What `git ls-files` returned last; the tree is these plus the doc paths.
    @State private var listedPaths: [String] = []
    @State private var files: [FileNode] = []
    @State private var expanded: Set<String> = []
    @State private var filesLoaded = false
    @State private var loadGeneration = 0
    /// The tree's own selection: mirrors `model.docsPath`, but is re-applied once the row exists
    /// (List drops a selection whose row isn't in the outline yet, e.g. inside a collapsed folder).
    @State private var treeSelection: String?
    @State private var creating: ProjectDoc.Kind?
    /// Left panel: the project's file system (docs marked in it) or the docs-only list.
    @AppStorage("projects.sidebar") private var sidebar = Sidebar.files

    enum Sidebar: String { case files, docs }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    sidebarHeader
                    Divider()
                    switch sidebar {
                    case .files: fileTree
                    case .docs: docList
                    }
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 400, maxHeight: .infinity)
                detail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
        .onAppear {
            reload()
            if model.docsPath == nil { model.docsPath = ProjectDocs.claudeMD }
            treeSelection = model.docsPath
        }
        .onChange(of: model.docsPath) { _, path in reveal(path) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .sheet(item: $creating) { kind in
            NewDocSheet(project: project, kind: kind) { path in
                reload()
                model.docsPath = path
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let path = model.docsPath {
            if let doc = docIndex.byPath[path] ?? markdownFile(path) {
                DocEditor(project: project, doc: doc, onSaved: reloadDocs) { link in open(link) }
                    .id(project.id.uuidString + path)
            } else {
                FilePreviewPane(project: project, path: path)
            }
        } else {
            Text("Выберите файл").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A markdown file that isn't one of the project docs still opens in the markdown editor.
    private func markdownFile(_ path: String) -> ProjectDoc? {
        guard ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()),
              let url = ProjectDocs.url(path, root: project.url), FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return ProjectDoc(kind: .spec, path: path, linked: false, exists: true)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Picker("", selection: $sidebar) {
                Text("Файлы").tag(Sidebar.files)
                Text("Документы").tag(Sidebar.docs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            Spacer(minLength: 0)
            Menu {
                Button("Новый спек…") { creating = .spec }
                Button("Новое правило контекста…") { creating = .context }
            } label: { Label("Новый документ", systemImage: "plus").labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Новый документ проекта")
            if sidebar == .files {
                Button { expanded = [] } label: {
                    Label("Свернуть все папки", systemImage: "arrow.down.right.and.arrow.up.left").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Свернуть все папки")
            }
            Button { reload() } label: { Label("Обновить", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Обновить")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var fileTree: some View {
        FileTreeView(nodes: files, docs: docIndex,
                     selection: Binding(get: { treeSelection }, set: { p in
                         guard let p else { return }
                         treeSelection = p
                         model.docsPath = p
                     }),
                     expanded: $expanded,
                     menu: { AnyView(fileMenu($0)) })
            .help("Файлы проекта без игнорируемых .gitignore. Документы (CLAUDE.md, спеки, контекст) выделены значком.")
    }

    @ViewBuilder
    private func fileMenu(_ path: String) -> some View {
        if let doc = docIndex.byPath[path] {
            menu(doc)
        } else {
            if markdownFile(path) != nil {
                Button("Подключить в CLAUDE.md как спек") { linkIntoClaudeMD(path) }
            }
            if let url = ProjectDocs.url(path, root: project.url) {
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Открыть в редакторе кода") { model.openInEditor(projectID: project.id, root: project.url, files: [url]) }
            }
        }
    }

    /// Expands the folders down to `path` so the selection is visible in the tree.
    private func reveal(_ path: String?) {
        guard let path else { treeSelection = nil; return }
        let closed = ProjectFiles.ancestors(of: path).filter { !expanded.contains($0) }
        expanded.formUnion(closed)
        if closed.isEmpty { treeSelection = path } else { reselectLater() }
    }

    /// Selects `model.docsPath` in the tree after the outline has added the rows just expanded or loaded.
    private func reselectLater() {
        treeSelection = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            treeSelection = model.docsPath
        }
    }

    private var docList: some View {
        List(selection: Binding(get: { model.docsPath }, set: { if let p = $0 { model.docsPath = p } })) {
            ForEach(ProjectDoc.Kind.allCases, id: \.self) { kind in
                Section {
                    ForEach(docs.filter { $0.kind == kind }) { doc in
                        DocRow(doc: doc).tag(doc.path)
                            .contextMenu { menu(doc) }
                    }
                    if kind != .description && docs.allSatisfy({ $0.kind != kind }) {
                        Text(kind == .spec ? "Нет спеков" : "Нет файлов контекста")
                            .font(.caption).foregroundStyle(.tertiary).selectionDisabled()
                    }
                } header: {
                    HStack {
                        Text(kind.title)
                        Spacer()
                        if kind != .description {
                            Button { creating = kind } label: {
                                Label(kind == .spec ? "Новый спек" : "Новое правило", systemImage: "plus").labelStyle(.iconOnly)
                            }
                                .buttonStyle(.borderless)
                                .help(kind == .spec ? "Новый спек (docs/…) — подключится в CLAUDE.md"
                                                    : "Новое правило (.claude/rules/…) — Claude Code загружает его сам")
                        }
                    }
                }
            }
        }
        .help("Спеки — файлы, на которые ссылается CLAUDE.md (@docs/arch.md) или лежащие в docs/. Контекст — CLAUDE.local.md, AGENTS.md, .claude/rules/.")
    }

    @ViewBuilder
    private func menu(_ doc: ProjectDoc) -> some View {
        if doc.kind == .spec && !doc.linked {
            Button("Подключить в CLAUDE.md") { linkIntoClaudeMD(doc.path) }
        }
        if let url = ProjectDocs.url(doc.path, root: project.url), doc.exists {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Открыть в редакторе кода") { model.openInEditor(projectID: project.id, root: project.url, files: [url]) }
        }
    }

    /// Re-reads the docs only (after a save or a CLAUDE.md edit): the file list itself hasn't changed.
    private func reloadDocs() {
        docs = ProjectDocs.discover(root: project.url)
        docIndex = DocIndex(docs)
        files = ProjectFiles.tree(listedPaths + docs.map(\.path))
    }

    /// Re-reads docs and the project's file list (git runs off the main thread; a stale result is dropped).
    private func reload() {
        reloadDocs()
        let root = project.url
        let git = model.git?.executable
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            let paths = await Task.detached { ProjectFiles.list(root: root, git: git) }.value
            guard generation == loadGeneration else { return }
            listedPaths = paths
            files = ProjectFiles.tree(paths + docs.map(\.path))
            if !filesLoaded {
                // First load: open the folders holding specs and the current selection.
                filesLoaded = true
                for doc in docs { expanded.formUnion(ProjectFiles.ancestors(of: doc.path)) }
                if let path = model.docsPath { expanded.formUnion(ProjectFiles.ancestors(of: path)) }
                reselectLater()
            }
        }
    }

    private func linkIntoClaudeMD(_ path: String) {
        let url = project.url.appendingPathComponent(ProjectDocs.claudeMD)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try ProjectDocs.link(path, into: text).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = "Не удалось обновить CLAUDE.md: \(error.localizedDescription)"
        }
        reloadDocs()
    }

    /// A link clicked in the preview: a project doc opens here, anything else in its app.
    private func open(_ link: String) {
        if let url = URL(string: link), let scheme = url.scheme, scheme != "artel-doc" {
            NSWorkspace.shared.open(url)
            return
        }
        let path = link.hasPrefix("artel-doc:") ? String(link.dropFirst("artel-doc:".count)) : link
        let rel = (path.removingPercentEncoding ?? path)
        if !docs.contains(where: { $0.path == rel }), let url = ProjectDocs.url(rel, root: project.url),
           FileManager.default.fileExists(atPath: url.path) {
            // Not a markdown doc we list (e.g. a source file): open it in the code editor.
            if url.pathExtension.lowercased() != "md" {
                model.openInEditor(projectID: project.id, root: project.url, files: [url])
                return
            }
            docs.append(ProjectDoc(kind: .spec, path: rel, linked: false, exists: true))
        }
        model.docsPath = rel
    }
}

private struct DocRow: View {
    let doc: ProjectDoc

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
            if !doc.exists {
                Text("нет файла").font(.caption2).foregroundStyle(.red)
                    .help("CLAUDE.md ссылается на файл, которого нет")
            } else if doc.kind == .spec && !doc.linked {
                Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                    .help("Не подключён в CLAUDE.md — агент не увидит его сам. Правый клик → «Подключить».")
            }
        }
    }
}

/// Markdown editor with preview for one project document.
private struct DocEditor: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let doc: ProjectDoc
    let onSaved: () -> Void
    let openLink: (String) -> Void

    @State private var text = ""
    @State private var saved = ""
    @State private var modified: Date?
    @State private var loaded = false
    @State private var watcher: FileWatcher?

    private var url: URL? { ProjectDocs.url(doc.path, root: project.url) }
    private var dirty: Bool { loaded && text != saved }
    private var isClaudeMD: Bool { doc.path == ProjectDocs.claudeMD }
    private var invalid: Bool { isClaudeMD && !ProjectValidator.hasDescription(text) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(doc.path).font(.callout.monospaced())
                if dirty {
                    Text("не сохранено").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                MarkdownModePicker()
                Button("Отменить") { text = saved }.disabled(!dirty)
                Button("Сохранить") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.glassProminent)
                    .disabled(!dirty || invalid)
                    .help(invalid ? "В CLAUDE.md обязателен раздел «Описание» с текстом" : "Сохранить (⌘S)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if invalid {
                Label("В CLAUDE.md нужен заполненный раздел «## Описание» — без него проект не сохранить.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            if !doc.exists && !loaded {
                VStack(spacing: 10) {
                    Text("Файла \(doc.path) нет").foregroundStyle(.secondary)
                    Button("Создать") { create() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownPane(text: $text, referencesForDrop: { urls in
                    // Project files dropped into a doc become @path references.
                    urls.map { url in
                        let root = project.url.resolvingSymlinksInPath().path + "/"
                        let p = url.resolvingSymlinksInPath().path
                        return p.hasPrefix(root) ? "@" + p.dropFirst(root.count) : url.absoluteString
                    }
                }, openLink: { openLink($0.absoluteString) })
            }
        }
        .onAppear {
            load()
            // Pick up edits made elsewhere (an agent, another editor) while there are no local changes.
            if let url { watcher = FileWatcher(url: url) { reloadIfChangedOutside() } }
        }
        .onDisappear {
            watcher = nil
            if dirty && !invalid { save() }
        }
    }

    private func reloadIfChangedOutside() {
        if !dirty, let url, let m = mtime(url), m != modified { load() }
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func load() {
        guard let url, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = content
        saved = content
        modified = mtime(url)
        loaded = true
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            saved = text
            modified = mtime(url)
            onSaved()
        } catch {
            model.errorMessage = "Не удалось сохранить \(doc.path): \(error.localizedDescription)"
        }
    }

    private func create() {
        text = isClaudeMD ? ProjectValidator.claudeMDTemplate(projectName: project.name)
                          : "# \(((doc.name as NSString).deletingPathExtension))\n\n"
        saved = ""
        loaded = true
    }
}

/// "New spec / rule" dialog.
private struct NewDocSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let kind: ProjectDoc.Kind
    let created: (String) -> Void
    @State private var name = ""
    @State private var link = true

    var body: some View {
        let path = ProjectDocs.newPath(kind: kind, name: name)
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .spec ? "Новый спек" : "Новое правило контекста").font(.title3.bold())
            TextField(kind == .spec ? "arch, stack, api…" : "style, testing…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if path != nil { create(path!) } }
            Text(path.map { "Файл: \($0)" } ?? " ").font(.caption.monospaced()).foregroundStyle(.secondary)
            if kind == .spec {
                Toggle("Подключить в CLAUDE.md (@\(path ?? "docs/…"))", isOn: $link)
            } else {
                Text("Claude Code загружает .claude/rules/*.md автоматически.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Создать") { if let path { create(path) } }
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
                let title = ((url.lastPathComponent as NSString).deletingPathExtension)
                try "# \(title)\n\n".write(to: url, atomically: true, encoding: .utf8)
            }
            if kind == .spec && link {
                let md = project.url.appendingPathComponent(ProjectDocs.claudeMD)
                let text = (try? String(contentsOf: md, encoding: .utf8)) ?? ""
                try ProjectDocs.link(path, into: text).write(to: md, atomically: true, encoding: .utf8)
            }
            created(path)
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

extension ProjectDoc.Kind: Identifiable {
    public var id: String { rawValue }
}
