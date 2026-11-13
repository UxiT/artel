import ArtelCore
import AppKit
import Quartz
import SwiftUI

/// Project docs looked up by path, and how many docs each folder holds (computed once per reload).
struct DocIndex {
    var byPath: [String: ProjectDoc] = [:]
    var counts: [String: Int] = [:]

    init(_ docs: [ProjectDoc] = []) {
        for doc in docs {
            byPath[doc.path] = doc
            for folder in ProjectFiles.ancestors(of: doc.path) { counts[folder, default: 0] += 1 }
        }
    }
}

/// The project's file system as an outline. Project docs (CLAUDE.md, specs, context files) are marked in place.
struct FileTreeView: View {
    let nodes: [FileNode]
    let docs: DocIndex
    @Binding var selection: String?
    @Binding var expanded: Set<String>
    let menu: (String) -> AnyView

    var body: some View {
        List(selection: $selection) {
            FileTreeRows(nodes: nodes, docs: docs, expanded: $expanded, menu: menu)
        }
    }
}

private struct FileTreeRows: View {
    let nodes: [FileNode]
    let docs: DocIndex
    @Binding var expanded: Set<String>
    let menu: (String) -> AnyView

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(node.path) },
                    set: { if $0 { expanded.insert(node.path) } else { expanded.remove(node.path) } }
                )) {
                    FileTreeRows(nodes: children, docs: docs, expanded: $expanded, menu: menu)
                } label: {
                    FolderRow(node: node, docCount: docs.counts[node.path] ?? 0)
                        .contextMenu { menu(node.path) }
                }
            } else {
                FileRow(node: node, doc: docs.byPath[node.path])
                    .tag(node.path)
                    .contextMenu { menu(node.path) }
            }
        }
    }
}

private struct FolderRow: View {
    let node: FileNode
    let docCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 0)
            if docCount > 0 {
                Text("\(docCount)").font(.caption2).foregroundStyle(.secondary)
                    .help("Документов проекта в папке: \(docCount)")
            }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    let doc: ProjectDoc?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(doc == nil ? Color.secondary : Color.accentColor)
            Text(node.name).lineLimit(1)
                .fontWeight(doc == nil ? .regular : .medium)
            Spacer(minLength: 0)
            if let doc {
                if !doc.exists {
                    Text("нет файла").font(.caption2).foregroundStyle(.red)
                        .help("CLAUDE.md ссылается на файл, которого нет")
                } else if doc.kind == .spec && !doc.linked {
                    Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                        .help("Спек не подключён в CLAUDE.md — агент не увидит его сам. Правый клик → «Подключить».")
                } else {
                    Text(doc.kind == .context ? "контекст" : doc.kind == .spec ? "спек" : "описание")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .help(node.path)
    }

    private var icon: String {
        if let doc {
            return doc.kind == .description ? "doc.richtext" : doc.kind == .spec ? "doc.text" : "brain"
        }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "icns", "heic", "webp", "pdf": return "photo"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "sh", "zsh", "bash": return "terminal"
        case "": return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Read-only preview of any file (source code, images, PDF…) via Quick Look.
/// One view is reused across files (only `previewItem` changes): calling `close()` while SwiftUI tears
/// the view down trips a Quick Look assertion.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }
}

/// A non-markdown project file: header with actions, Quick Look preview below.
struct FilePreviewPane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let path: String

    var body: some View {
        let url = ProjectDocs.url(path, root: project.url)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let url {
                    Button("Открыть в редакторе кода") {
                        model.openInEditor(projectID: project.id, root: project.url, files: [url])
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Показать в Finder", systemImage: "folder").labelStyle(.iconOnly)
                    }
                    .help("Показать в Finder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let url, FileManager.default.fileExists(atPath: url.path) {
                QuickLookPreview(url: url)
            } else {
                Text("Файла нет").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
