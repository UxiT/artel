import ArtelCore
import AppKit
import SwiftUI

struct TaskFilter: Equatable {
    /// Empty = all projects.
    var projects: Set<UUID> = []
    /// Default: everything except closed tasks.
    var statuses: Set<TaskStatus> = Set(TaskStatus.allCases.filter { !$0.isClosed })
    var search = ""

    var isDefault: Bool { self == TaskFilter(search: search) }

    func matches(_ t: ArtelTask) -> Bool {
        if !projects.isEmpty && !projects.contains(t.projectID) { return false }
        if !statuses.contains(t.status) { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return t.taskID.localizedCaseInsensitiveContains(q) || t.title.localizedCaseInsensitiveContains(q)
                || t.body.localizedCaseInsensitiveContains(q)
        }
        return true
    }
}

struct TaskLaunchRequest: Identifiable {
    let id = UUID()
    var taskID: String  // ArtelTask.id
    /// Existing session to run the task in; nil = new session.
    var sessionID: String?
}

struct CommitRequest: Identifiable {
    let id = UUID()
    var projectID: UUID
    var changes: [String]
    var message: String
}

enum FocusRequest: Equatable {
    case search, docsSearch
}

/// Drag payloads are plain strings; tasks are prefixed to tell them from session ids.
enum DragPayload {
    static let taskPrefix = "task:"
    static func task(_ t: ArtelTask) -> String { taskPrefix + t.id }
    static func taskID(from payload: String) -> String? {
        payload.hasPrefix(taskPrefix) ? String(payload.dropFirst(taskPrefix.count)) : nil
    }
}

private struct TaskDragSource: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: ArtelTask

    func body(content: Content) -> some View {
        content.onDrag {
            model.beginTaskDrag()
            return NSItemProvider(object: DragPayload.task(task) as NSString)
        }
    }
}

extension View {
    func taskDragSource(_ task: ArtelTask) -> some View {
        modifier(TaskDragSource(task: task))
    }
}

extension AppModel {
    func beginTaskDrag() {
        isDraggingTask = true
        Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons != 0 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.isDraggingTask = false
        }
    }

    // MARK: - Loading

    func reloadAllTasks() {
        for p in state.projects {
            reloadTasks(of: p)
            reloadNoTasks(of: p)
        }
        refreshArtelDirty()
    }

    func reloadTasks(of project: Project) {
        let loaded = TaskStore.load(project)
        taskFingerprints[project.id] = TaskStore.fingerprint(project)
        // Keep in-memory versions with unsaved edits; the file will catch up when the save lands.
        let pending = Set(pendingTaskSaves.keys)
        var merged = loaded.filter { !pending.contains($0.id) }
        merged += tasks.filter { $0.projectID == project.id && pending.contains($0.id) }
        tasks.removeAll { $0.projectID == project.id }
        tasks.append(contentsOf: merged)
        for t in loaded { taskBaselines[t.id] = t }
    }

    /// Called from the 2 s timer: picks up task files changed by agents, the operator or git.
    func pollTasks(checkGit: Bool) {
        for p in state.projects {
            if TaskStore.fingerprint(p) != taskFingerprints[p.id] { reloadTasks(of: p) }
            if NoTaskStore.fingerprint(p, preserving: liveNoTaskSessionIDs) != noTaskFingerprints[p.id] {
                reloadNoTasks(of: p)
            }
        }
        if checkGit { refreshArtelDirty() }
        // The open task window's history: a stat, not a parse; the timeline reloads on `historyVersion`.
        if let t = task(openedTaskID) {
            let url = t.directory.appendingPathComponent(TaskHistory.fileName)
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if m != openedHistoryModified {
                openedHistoryModified = m
                historyVersion += 1
            }
        }
    }

    func refreshArtelDirty() {
        guard let git else { return }
        // Not a repository: `git status` would report an enclosing repository, if any.
        let projects = state.projects.filter { $0.storeArtelInGit && $0.isGitRepository }
        Task.detached {
            var dirty: Set<UUID> = []
            for p in projects where !git.artelChanges(repo: p.path, taskDir: TaskStore.dirName(p)).isEmpty { dirty.insert(p.id) }
            await MainActor.run { [dirty] in self.artelDirty = dirty }
        }
    }

    // MARK: - Queries

    func task(_ id: String?) -> ArtelTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    func task(for record: SessionRecord) -> ArtelTask? {
        guard let taskID = record.taskID else { return nil }
        return tasks.first { $0.projectID == record.projectID && $0.taskID == taskID }
    }

    var selectedTask: ArtelTask? { task(selectedTaskID) }

    /// Appends to the task's history.jsonl; failures only cost a history line.
    func record(_ task: ArtelTask, _ entry: TaskHistoryEntry) {
        try? TaskHistory.append(entry, in: task.directory)
        historyVersion += 1
    }

    /// ⌘F: the task list lives in the sidebar (sessions) or on the board; the projects section has neither.
    /// ⌘F: the documentation search in the projects section, the task search elsewhere.
    func request(focus: FocusRequest) {
        if section == .projects && !showsProjectFiles {
            focusRequest = .docsSearch
            return
        }
        if section != .tasks { section = .tasks }
        focusRequest = focus
    }

    /// Opens a project document in the projects section.
    func openProjectDocs(_ projectID: UUID, path: String? = ProjectDocs.claudeMD) {
        docsProjectID = projectID
        docsPath = path
        section = .projects
    }

    func sessions(for task: ArtelTask) -> [SessionRecord] {
        state.sessions.filter { $0.projectID == task.projectID && $0.taskID == task.taskID }
    }

    /// The live session currently attached to the task, if any.
    func activeSession(for task: ArtelTask) -> SessionRecord? {
        sessions(for: task).first { status($0.id).activity != .exited }
    }

    /// Tasks of a project after filtering, sorted by status, then most recently changed.
    /// The filter of the sidebar: the task board's search and filters, none in the workspace.
    var sidebarFilter: TaskFilter { section == .workspace ? TaskFilter() : taskFilter }

    func visibleTasks(of project: Project) -> [ArtelTask] {
        let taskFilter = sidebarFilter
        guard taskFilter.projects.isEmpty || taskFilter.projects.contains(project.id) else { return [] }
        return tasks.filter { $0.projectID == project.id && taskFilter.matches($0) }.sorted { a, b in
            if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
            return a.updated > b.updated
        }
    }

    /// Why the task can't be dragged into the workspace right now (nil = it can).
    func launchBlocker(for task: ArtelTask) -> String? {
        if task.status.isClosed { return "Задача закрыта" }
        if launchingTasks.contains(task.id) { return "Задача запускается" }
        if let s = activeSession(for: task), status(s.id).activity == .working || status(s.id).activity == .starting {
            return "Задача уже выполняется в сессии «\(s.name)»"
        }
        return nil
    }

    // MARK: - Editing

    /// "Новая задача" (⌘N): opens the task window with a draft; the project is chosen there.
    func requestNewTask(projectID: UUID? = nil, title: String = "") {
        // A draft already on screen keeps what was typed.
        guard newTaskDraft == nil else { return }
        guard let project = (projectID ?? focusedOrSelectedProjectID).flatMap(project) ?? state.projects.first
        else { return }
        newTaskInTaskWindow = keyWindowIsTask && isTaskWindowOpen
        newTaskDraft = TaskDraft(project: project, title: title,
                                 body: state.settings.taskTemplate ?? ArtelTask.bodyTemplate(),
                                 agent: state.settings.effectiveDefaultAgentID)
    }

    /// The task window is on screen (an existing task or an archived session).
    var isTaskWindowOpen: Bool { openedTaskID != nil || openedNoTaskID != nil }

    /// A launch / done / editor-choice dialog or an error alert is on screen.
    var hasFlowDialog: Bool { taskLaunch != nil || doneRequest != nil || editorRequest != nil || errorMessage != nil }

    /// Dialogs follow the window the operator is working in; one already on screen stays where it is.
    func syncFlowHost() {
        guard !hasFlowDialog else { return }
        flowHostIsTask = keyWindowIsTask && isTaskWindowOpen
    }

    /// Called whenever a window becomes key. Panels and popovers don't count; a sheet counts as its parent.
    func noteKeyWindow(_ window: NSWindow) {
        let w = window.sheetParent ?? window
        guard w.styleMask.contains(.titled) else { return }
        keyWindowIsMain = w === mainWindow
        keyWindowIsTask = w === taskWindow
        syncFlowHost()
    }

    /// The task window is closing: forget what it showed and where dialogs go.
    func taskWindowWillClose(_ window: NSWindow) {
        guard window === taskWindow else { return }
        flushTaskSaves()
        taskWindow = nil
        openedTaskID = nil
        openedNoTaskID = nil
        keyWindowIsTask = false
        flowHostIsTask = false
        newTaskInTaskWindow = false
    }

    /// ⌘W: in the main window it closes the focused session (an operator choice); elsewhere it closes the window.
    func closeCommand() {
        if keyWindowIsMain {
            requestStopSession()
        } else if let w = NSApp.keyWindow, w.sheetParent == nil {
            w.performClose(nil)
        }
    }

    var closeCommandTitle: String { keyWindowIsMain ? "Закрыть сессию…" : "Закрыть окно" }
    var closeCommandDisabled: Bool {
        keyWindowIsMain && focusedSessionID == nil && state.expandedSessionID == nil
    }

    /// Creates the drafted task; the task window switches from the draft to it.
    @discardableResult
    func createTask(_ draft: TaskDraft) -> ArtelTask? {
        guard let project = project(draft.projectID) else {
            errorMessage = "Проект задачи не найден"
            return nil
        }
        guard draft.canCreate else { return nil }
        do {
            let existing = tasks.filter { $0.projectID == project.id }
            let task = try TaskStore.create(draft, project: project, existing: existing)
            tasks.append(task)
            record(task, TaskHistoryEntry(actor: .operator, kind: .created, text: "Задача создана"))
            taskFingerprints[project.id] = TaskStore.fingerprint(project)
            taskBaselines[task.id] = task
            newTaskDraft = nil
            openTask(task.id)
            refreshArtelDirty()
            return task
        } catch {
            errorMessage = "Не удалось создать задачу: \(error.localizedDescription)"
            return nil
        }
    }

    /// Applies an edit in memory immediately and writes task.md shortly after (typing-friendly).
    func updateTask(_ task: ArtelTask, debounce: Bool = true) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var t = task
        // Status changes made in Artel are the operator's (a launch moves a new task to "in progress" on their behalf).
        if tasks[i].status != t.status {
            record(t, TaskHistoryEntry(actor: .operator, kind: .status, from: tasks[i].status, to: t.status))
        }
        t.updated = Date()
        tasks[i] = t
        pendingTaskSaves[t.id]?.cancel()
        let id = t.id
        pendingTaskSaves[id] = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled, let self else { return }
            self.writeTask(id)
        }
    }

    func flushTaskSaves() {
        for id in Array(pendingTaskSaves.keys) { writeTask(id) }
    }

    private func writeTask(_ id: String) {
        pendingTaskSaves[id]?.cancel()
        pendingTaskSaves.removeValue(forKey: id)
        guard var t = task(id), let project = project(t.projectID) else { return }
        // task.md may have been edited outside Artel since we loaded it: merge, don't clobber.
        if let base = taskBaselines[id], let text = try? String(contentsOf: t.file, encoding: .utf8),
           let disk = TaskFile.parse(text, projectID: t.projectID, directory: t.directory), disk != base {
            t = ArtelTask.merged(local: t, base: base, disk: disk)
            if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i] = t }
        }
        do {
            try TaskStore.save(t, project: project)
            taskBaselines[id] = t
            taskFingerprints[project.id] = TaskStore.fingerprint(project)
            if project.storeArtelInGit { artelDirty.insert(project.id) }
        } catch {
            errorMessage = "Не удалось сохранить \(t.taskID): \(error.localizedDescription)"
        }
    }

    // MARK: - Launching

    /// Entry point for drag-and-drop / ⌘R: validates and opens the launch dialog.
    func requestLaunch(taskID: String, intoSession sessionID: String?) {
        guard let task = task(taskID) else { return }
        if let blocker = launchBlocker(for: task) {
            errorMessage = blocker
            return
        }
        if let sessionID {
            guard let record = record(sessionID) else { return }
            let activity = status(sessionID).activity
            guard Self.canReceiveTask(activity) else {
                errorMessage = "Сессия «\(record.name)» сейчас занята (\(activity.title)). Перетащите задачу на «+», чтобы открыть новую."
                return
            }
        }
        guard tmux != nil, agentPath(for: task.agent) != nil else {
            errorMessage = "Сначала установите tmux и \(agent(for: task).displayName)."
            return
        }
        taskLaunch = TaskLaunchRequest(taskID: taskID, sessionID: sessionID)
    }

    /// A session accepts a task only when nothing runs in it.
    static func canReceiveTask(_ activity: SessionActivity) -> Bool {
        [.ready, .idle, .exited, .error].contains(activity)
    }

    /// The prompt frame from settings, or the built-in one.
    var promptFrame: String { state.settings.promptFrame ?? PromptTemplate.defaultFrame }

    /// Confirmed launch: (worktree) → task.md update → session (new, continued or restarted in place).
    /// A task runs in the project checkout unless it asks for — or already has — its own worktree.
    func launch(_ request: TaskLaunchRequest, model: String?, saveModel: Bool, clearContext: Bool, useWorktree: Bool) {
        // The prompt is the task text: unsaved edits go in with it.
        guard saveDraft(.task(request.taskID)) else { return }
        guard var task = task(request.taskID), let project = project(task.projectID) else { return }
        let wantsWorktree = useWorktree || task.worktree != nil
        if wantsWorktree && git == nil {
            errorMessage = "Для worktree нужен git."
            return
        }
        if wantsWorktree && task.worktree == nil && !project.isGitRepository {
            errorMessage = "Проект «\(project.name)» не git-репозиторий — отдельный worktree недоступен."
            return
        }
        let branch = task.branch ?? WorktreeLayout.branch(for: task)
        let worktree = task.worktree ?? WorktreeLayout.path(project: project, taskID: task.taskID)
        let base = baseBranch(for: project)
        let git = self.git
        launchingTasks.insert(task.id)

        Task {
            if wantsWorktree, let git {
                let result: Result<Void, Error> = await Task.detached {
                    Result { try git.ensureWorktree(repo: project.path, path: worktree, branch: branch, base: base,
                                                taskDir: TaskStore.dirName(project)) }
                }.value
                if case .failure(let error) = result {
                    launchingTasks.remove(task.id)
                    errorMessage = "Не удалось подготовить worktree для \(task.taskID): \(error.localizedDescription)"
                    return
                }
            }
            launchingTasks.remove(task.id)
            // Re-read: the task may have been edited while git was working.
            task = self.task(request.taskID) ?? task
            let cwd = wantsWorktree ? worktree : project.path
            if wantsWorktree {
                task.branch = branch
                task.worktree = worktree
            }
            if task.status == .new { task.status = .inProgress }
            if saveModel, let model { task.model = model }
            record(task, TaskHistoryEntry(actor: .artel, kind: .launch,
                                          text: "Агент запущен"
                                              + (request.sessionID == nil ? " в новой сессии" : " в сессии «\(self.record(request.sessionID!)?.name ?? "")»")
                                              + (wantsWorktree ? ", worktree \(branch)" : ", в проекте")
                                              + ((model ?? task.model).map { ", модель \($0)" } ?? "")))
            let prompt = TaskPrompt.build(task: task, project: project, worktree: wantsWorktree ? worktree : nil,
                                          frame: promptFrame)
            let sessionModel = model ?? task.model

            if let sessionID = request.sessionID, var record = record(sessionID) {
                let sameTask = record.taskID == task.taskID && record.projectID == task.projectID && record.cwd == cwd
                if sameTask && status(sessionID).activity != .exited {
                    continueInSession(record, prompt: prompt, clearContext: clearContext, model: sessionModel)
                } else {
                    // Different task (or dead process): restart the agent in this slot, in the task's directory.
                    tmux?.kill(record.tmuxName)
                    terminals.discard(record.id)
                    record.name = Self.sessionName(for: task)
                    record.projectID = task.projectID
                    record.taskID = task.taskID
                    record.agentID = task.agent
                    record.cwd = cwd
                    record.model = sessionModel
                    record.permissionMode = project.permissionMode
                    record.conversationID = UUID().uuidString.lowercased()
                    record.exited = false
                    replace(record)
                    statuses[record.id] = SessionStatus(activity: .starting)
                    terminalEpoch[record.id, default: 0] += 1
                    launch(record, resume: false, prompt: prompt)
                    saveNow()
                }
                if !task.sessions.contains(record.id) { task.sessions.append(record.id) }
                focus(record.id)
            } else {
                var record = SessionRecord(name: Self.sessionName(for: task), projectID: project.id, cwd: cwd,
                                           agentID: task.agent, model: sessionModel,
                                           permissionMode: project.permissionMode, tabID: selectedTabID)
                record.taskID = task.taskID
                record.conversationID = UUID().uuidString.lowercased()
                state.lastSessionSettings = SessionLaunchSettings(record)
                state.sessions.append(record)
                saveNow()
                statuses[record.id] = SessionStatus(activity: .starting)
                // Tasks for the record must be visible to launch() (it adds the task dir to --add-dir).
                updateTask(task, debounce: false)
                launch(record, resume: false, prompt: prompt)
                task.sessions.append(record.id)
                focusedSessionID = record.id
            }
            updateTask(task, debounce: false)
        }
    }

    /// Same task, live agent: optionally `/clear` (and `/model`), then paste the prompt.
    func continueInSession(_ record: SessionRecord, prompt: String, clearContext: Bool, model: String?) {
        guard let tmux else { return }
        var record = record
        let name = record.tmuxName
        let id = record.id
        // kimi's `/model` has no argument form: a model change means restarting the process
        // (the context is lost, same as clearing it).
        if agent(for: record).agentID == KimiCodeAgent.id, let model, model != record.model {
            tmux.kill(name)
            terminals.discard(id)
            record.model = model
            record.exited = false
            replace(record)
            statuses[id] = SessionStatus(activity: .starting)
            terminalEpoch[id, default: 0] += 1
            launch(record, resume: false, prompt: prompt)
            return
        }
        Task {
            do {
                if clearContext {
                    // `/clear` works in both CLIs (kimi alias for a fresh in-place session).
                    try tmux.sendLine("/clear", to: name)
                    // Wait for SessionStart(clear) → ready, max ~6 s.
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .milliseconds(200))
                        if status(id).activity == .ready { break }
                    }
                }
                if let model, model != record.model {
                    try tmux.sendLine("/model \(model)", to: name)
                    try? await Task.sleep(for: .milliseconds(800))
                    record.model = model
                    replace(record)
                }
                try tmux.paste(prompt, into: name, submit: true)
            } catch {
                errorMessage = "Не удалось передать задачу в сессию: \(error.localizedDescription)"
            }
        }
    }

    static func sessionName(for task: ArtelTask) -> String { "\(task.taskID) · \(task.title)" }

    // MARK: - Commit .artel

    func requestCommit(projectID: UUID) {
        guard let git, let project = project(projectID) else { return }
        flushTaskSaves()
        let taskDir = TaskStore.dirName(project)
        let changes = git.artelChanges(repo: project.path, taskDir: taskDir)
        guard !changes.isEmpty else {
            errorMessage = "В \(taskDir)/ проекта «\(project.name)» нет изменений."
            artelDirty.remove(projectID)
            return
        }
        commitRequest = CommitRequest(projectID: projectID, changes: changes,
                                      message: Self.commitMessage(changes: changes, taskDir: taskDir,
                                                                           tasks: tasks.filter { $0.projectID == projectID }))
    }

    func performCommit(_ request: CommitRequest, message: String) {
        guard let git, let project = project(request.projectID) else { return }
        do {
            try git.commitArtel(repo: project.path, taskDir: TaskStore.dirName(project), message: message)
            artelDirty.remove(project.id)
            commitRequest = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `artel: ARTEL-12 → in-progress, ARTEL-14 created`
    static func commitMessage(changes: [String], taskDir: String = TaskStore.folderName, tasks: [ArtelTask]) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        for line in changes {
            // porcelain: "XY path"
            let path = String(line.dropFirst(3))
            let comps = path.split(separator: "/")
            guard comps.count >= 3, comps[0] == taskDir, comps[1] == "tasks" else { continue }
            let folder = String(comps[2])
            guard let task = tasks.first(where: { $0.directory.lastPathComponent == folder }), seen.insert(task.taskID).inserted else { continue }
            let added = line.hasPrefix("??") || line.hasPrefix("A")
            parts.append(added ? "\(task.taskID) created" : "\(task.taskID) → \(task.status.rawValue)")
        }
        return parts.isEmpty ? "artel: update tasks" : "artel: " + parts.joined(separator: ", ")
    }

    var focusedOrSelectedProjectID: UUID? {
        selectedTask?.projectID ?? focusedProjectID
    }
}
