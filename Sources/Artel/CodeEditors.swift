import ArtelCore
import AppKit
import SwiftUI

struct EditorApp: Identifiable, Hashable {
    var id: String { url.path }
    var bundleID: String
    var name: String
    var url: URL
    var version: String
    var isJetBrains: Bool { JetBrainsIDE.isCodeEditor(bundleID) }
}

/// Code editors installed on this Mac.
enum CodeEditors {
    static let knownOthers: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "dev.zed.Zed": "Zed",
        "com.apple.dt.Xcode": "Xcode",
        "com.sublimetext.4": "Sublime Text",
        "com.panic.Nova": "Nova",
        "com.exafunction.windsurf": "Windsurf",
    ]

    /// JetBrains IDEs first, then other editors; one entry per bundle id (newest version wins,
    /// e.g. "GoLand.app" vs "GoLand 2025.3.4.1.app").
    static func installed() -> [EditorApp] {
        var byID: [String: EditorApp] = [:]
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                    URL(fileURLWithPath: "/Applications/JetBrains Toolbox"), home.appendingPathComponent("Applications/JetBrains Toolbox")]
        var candidates: [URL] = []
        for d in dirs {
            candidates += ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        }
        for id in knownOthers.keys {
            candidates += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
        }
        for url in candidates {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            guard JetBrainsIDE.isCodeEditor(id) || knownOthers[id] != nil else { continue }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let name = JetBrainsIDE.codeEditors[id] ?? knownOthers[id] ?? url.deletingPathExtension().lastPathComponent
            let app = EditorApp(bundleID: id, name: name, url: url, version: version)
            if let existing = byID[id] {
                // Newer version wins; on a tie prefer the plain name ("GoLand.app" over "GoLand 2025.3.app").
                let order = existing.version.compare(version, options: .numeric)
                if order == .orderedDescending { continue }
                if order == .orderedSame && existing.url.lastPathComponent.count <= url.lastPathComponent.count { continue }
            }
            byID[id] = app
        }
        return byID.values.sorted { a, b in
            a.isJetBrains != b.isJetBrains ? a.isJetBrains : a.name < b.name
        }
    }

    static func open(_ urls: [URL], with app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, error in
            if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
        }
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var projectID: UUID
    var urls: [URL]
}

extension AppModel {
    /// Opens code in the project's editor. The first time: a matching JetBrains IDE is chosen
    /// automatically, otherwise the operator is asked; the choice is saved in the project.
    /// `root` (worktree or project folder) is opened too, so an IDE opens files inside the project.
    func openInEditor(projectID: UUID, root: URL, files: [URL] = []) {
        guard var project = project(projectID) else { return }
        let urls = [root] + files
        if let path = project.editorPath, FileManager.default.fileExists(atPath: path) {
            CodeEditors.open(urls, with: URL(fileURLWithPath: path))
            return
        }
        let installed = CodeEditors.installed()
        if let id = JetBrainsIDE.autoChoice(forProjectAt: project.url, installed: Set(installed.map(\.bundleID))),
           let app = installed.first(where: { $0.bundleID == id }) {
            project.editorPath = app.url.path
            updateProject(project)
            CodeEditors.open(urls, with: app.url)
            return
        }
        editorRequest = EditorRequest(projectID: projectID, urls: urls)
    }

    func chooseEditor(_ app: URL, for request: EditorRequest) {
        guard var project = project(request.projectID) else { return }
        project.editorPath = app.path
        updateProject(project)
        editorRequest = nil
        CodeEditors.open(request.urls, with: app)
    }

    /// Where a task's code lives: its worktree, else the project.
    func codeRoot(for task: ArtelTask) -> URL {
        if let wt = task.worktree, FileManager.default.fileExists(atPath: wt) { return URL(fileURLWithPath: wt) }
        return project(task.projectID)?.url ?? task.directory
    }
}

/// "Open code with…" — asked once per project.
struct EditorChoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest
    @State private var apps: [EditorApp] = []
    @State private var selection: EditorApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Code With").font(.title3.bold())
            Text("Project “\(model.project(request.projectID)?.name ?? "")”. Your choice is remembered for this project; you can change it in Project Settings.")
                .font(.callout).foregroundStyle(.secondary)
            List(apps, selection: $selection) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 24, height: 24)
                    Text(app.name)
                    Text(app.version).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if app.isJetBrains { Text("JetBrains").font(.caption2).foregroundStyle(.secondary) }
                }
                .tag(app)
            }
            .frame(height: 220)
            .overlay {
                if apps.isEmpty { Text("No code editors found").foregroundStyle(.secondary) }
            }
            HStack {
                Button("Other App…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url { model.chooseEditor(url, for: request); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let selection { model.chooseEditor(selection.url, for: request); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            apps = CodeEditors.installed()
            selection = apps.first
        }
    }
}

/// Project settings row: current editor + change / reset.
struct EditorSettingRow: View {
    @Binding var editorPath: String?
    @State private var apps: [EditorApp] = []

    var body: some View {
        Picker("Code Editor", selection: $editorPath) {
            Text("Ask on First Open").tag(String?.none)
            ForEach(apps) { app in
                Text(app.name + (app.isJetBrains ? " · JetBrains" : "")).tag(Optional(app.url.path))
            }
            if let editorPath, !apps.contains(where: { $0.url.path == editorPath }) {
                Text(URL(fileURLWithPath: editorPath).deletingPathExtension().lastPathComponent).tag(Optional(editorPath))
            }
        }
        .onAppear { apps = CodeEditors.installed() }
    }
}
