import ArtelCore
import AppKit
import Foundation

/// A markdown document open in the editor: the text on disk when editing began, and the edited text.
/// Changes are saved explicitly (⌘S, "Готово", Esc, ⌘⏎); unsaved documents carry a dot in lists.
struct MarkdownDraft: Equatable {
    var saved: String
    var text: String
    var dirty: Bool { saved != text }
}

/// Keys of the documents that can be edited: a project file or a task's text.
enum DocumentKey {
    case projectFile(UUID, String)
    case task(String)

    var raw: String {
        switch self {
        case .projectFile(let id, let path): "file|\(id.uuidString)|\(path)"
        case .task(let id): "task|\(id)"
        }
    }

    init?(raw: String) {
        let parts = raw.split(separator: "|", maxSplits: 2).map(String.init)
        switch parts.first {
        case "file" where parts.count == 3:
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .projectFile(id, parts[2])
        case "task" where parts.count == 2:
            self = .task(parts[1])
        default:
            return nil
        }
    }
}

/// "Ask the agent" about a documentation page, or a fragment of it.
struct DocsAgentRequest: Identifiable {
    let id = UUID()
    var projectID: UUID
    /// Project-relative page; nil = the documentation as a whole.
    var page: String?
    var fragment: DocsPrompt.Fragment?
}

extension AppModel {
    // MARK: - Documentation folder

    /// The project's documentation folder: the operator's choice, else what `DocsSite.detect` finds.
    func docsFolder(for project: Project) -> String? {
        if let chosen = project.docsFolder { return chosen }
        return DocsSite.detect(root: project.url)
    }

    func setDocsFolder(_ folder: String?, for projectID: UUID) {
        guard var p = project(projectID) else { return }
        p.docsFolder = folder
        updateProject(p)
    }

    /// Creates the documentation folder with a welcome page and remembers it for the project.
    @discardableResult
    func createDocs(project: Project, folder: String) -> String? {
        let dir = folder.isEmpty ? project.url : project.url.appendingPathComponent(folder, isDirectory: true)
        let index = (folder.isEmpty ? "" : folder + "/") + "index.md"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = project.url.appendingPathComponent(index)
            if !FileManager.default.fileExists(atPath: url.path) {
                try DocsSite.welcomePage(projectName: project.name).write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            errorMessage = "Не удалось создать документацию: \(error.localizedDescription)"
            return nil
        }
        setDocsFolder(folder, for: project.id)
        docsPath = index
        return index
    }

    // MARK: - Drafts

    func isEditing(_ key: DocumentKey) -> Bool { markdownDrafts[key.raw] != nil }
    func isDirty(_ key: DocumentKey) -> Bool { dirtyDocuments.contains(key.raw) }

    /// Opens the document in the editor with `text` as what's on disk (a draft already open is kept).
    func beginEditing(_ key: DocumentKey, saved: String, text: String? = nil) {
        if markdownDrafts[key.raw] == nil {
            markdownDrafts[key.raw] = MarkdownDraft(saved: saved, text: text ?? saved)
        }
        refreshDirty(key.raw)
    }

    func draftText(_ key: DocumentKey) -> String? { markdownDrafts[key.raw]?.text }

    func updateDraft(_ key: DocumentKey, text: String) {
        guard var d = markdownDrafts[key.raw], d.text != text else { return }
        d.text = text
        markdownDrafts[key.raw] = d
        refreshDirty(key.raw)
    }

    /// The file changed on disk while open without local changes: follow it.
    func reloadDraft(_ key: DocumentKey, saved: String) {
        guard var d = markdownDrafts[key.raw], !d.dirty, d.saved != saved else { return }
        d.saved = saved
        d.text = saved
        markdownDrafts[key.raw] = d
    }

    private func refreshDirty(_ raw: String) {
        let dirty = markdownDrafts[raw]?.dirty ?? false
        if dirty != dirtyDocuments.contains(raw) {
            if dirty { dirtyDocuments.insert(raw) } else { dirtyDocuments.remove(raw) }
        }
    }

    /// Writes the draft and keeps editing. false = not saved (the error is shown).
    @discardableResult
    func saveDraft(_ key: DocumentKey) -> Bool {
        guard var d = markdownDrafts[key.raw] else { return true }
        guard d.dirty else { return true }
        switch key {
        case .projectFile(let projectID, let path):
            guard let project = project(projectID), let url = ProjectDocs.url(path, root: project.url) else { return false }
            if path == ProjectDocs.claudeMD && !ProjectValidator.hasDescription(d.text) {
                errorMessage = "В CLAUDE.md нужен заполненный раздел «## Описание» — без него файл не сохранить."
                return false
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Не удалось сохранить \(path): \(error.localizedDescription)"
                return false
            }
        case .task(let id):
            guard var t = task(id) else { return false }
            t.body = d.text
            updateTask(t, debounce: false)
        }
        d.saved = d.text
        markdownDrafts[key.raw] = d
        refreshDirty(key.raw)
        docsVersion += 1
        return true
    }

    /// "Готово" / Esc / ⌘⏎: save and back to the preview. Stays in the editor if saving failed.
    func finishEditing(_ key: DocumentKey) {
        guard saveDraft(key) else { return }
        markdownDrafts[key.raw] = nil
        refreshDirty(key.raw)
    }

    /// Drops the changes and leaves the editor.
    func discardDraft(_ key: DocumentKey) {
        markdownDrafts[key.raw] = nil
        refreshDirty(key.raw)
    }

    /// Before quitting: saves every unsaved document. false = something could not be saved.
    func saveAllDrafts() -> Bool {
        var ok = true
        for raw in dirtyDocuments {
            if let key = DocumentKey(raw: raw), !saveDraft(key) { ok = false }
        }
        return ok
    }

    /// Unsaved documents of a project at or under `path` (a page or a folder).
    func dirtyDocuments(projectID: UUID, under path: String) -> [String] {
        dirtyDocuments.compactMap { raw in
            guard case .projectFile(let id, let p)? = DocumentKey(raw: raw), id == projectID,
                  p == path || p.hasPrefix(path + "/") else { return nil }
            return p
        }
    }

    /// Drafts of moved or deleted files: moved ones follow the file, deleted ones are dropped.
    func moveDrafts(projectID: UUID, from: String, to: String?) {
        for raw in Array(markdownDrafts.keys) {
            guard case .projectFile(let id, let p)? = DocumentKey(raw: raw), id == projectID,
                  let moved = DocsLinks.moved(p, from: from, to: to ?? from) else { continue }
            let draft = markdownDrafts.removeValue(forKey: raw)
            dirtyDocuments.remove(raw)
            if to != nil, let draft {
                let newKey = DocumentKey.projectFile(id, moved).raw
                markdownDrafts[newKey] = draft
                if draft.dirty { dirtyDocuments.insert(newKey) }
            }
        }
        if let current = docsPath, let moved = DocsLinks.moved(current, from: from, to: to ?? from) {
            docsPath = to == nil ? nil : moved
        }
    }

    // MARK: - Agent

    /// Starts an agent session in the project checkout with a documentation prompt. The page's unsaved changes
    /// are saved first and the page goes back to the preview, so the agent's edits show up live.
    func startDocsAgent(_ request: DocsAgentRequest, instruction: String, agentID: String) {
        guard let project = project(request.projectID) else { return }
        if let page = request.page {
            let key = DocumentKey.projectFile(project.id, page)
            if isEditing(key) {
                guard saveDraft(key) else { return }
                discardDraft(key)
            }
        }
        let agent = CodingAgents.agent(forID: agentID)
        let permission = agent.permissionModes.contains(project.permissionMode) ? project.permissionMode
            : (agent.permissionModes.first ?? "auto")
        let prompt = DocsPrompt.make(instruction: instruction, docsFolder: docsFolder(for: project) ?? DocsSite.defaultFolder,
                                     page: request.page, fragment: request.fragment)
        guard let id = startSession(project: project, name: DocsPrompt.sessionName(page: request.page, fragment: request.fragment != nil),
                                    model: project.defaultModel ?? state.settings.defaultModel(for: agentID),
                                    permissionMode: permission, prompt: prompt, agentID: agentID) else { return }
        docsAgentSessions[DocumentKey.projectFile(project.id, request.page ?? "").raw] = id
    }

    /// The live agent session started from this page, if any.
    func docsAgentSession(projectID: UUID, page: String?) -> SessionRecord? {
        docsAgentSessions[DocumentKey.projectFile(projectID, page ?? "").raw].flatMap { record($0) }
    }
}
