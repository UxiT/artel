import ArtelCore
import AppKit
import SwiftUI

/// Root of the task window scene: a separate, non-modal window showing the opened task or archived session.
/// The main window stays usable while it is open (sessions, board, drag-and-drop).
struct TaskWindowScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if let id = model.openedTaskID {
                TaskWindow(taskID: id).id(id)
            } else if let id = model.openedNoTaskID {
                NoTaskWindow(archiveID: id).id(id)
            } else {
                // Restored or emptied window: nothing to show. On reopening, this stale branch can appear
                // once more before the new item renders — dismiss only if nothing is open by then.
                Color.clear.onAppear {
                    DispatchQueue.main.async {
                        if !model.isTaskWindowOpen { dismissWindow(id: TaskWindowScene.id) }
                    }
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 1200, maxWidth: .infinity, minHeight: 600, idealHeight: 820, maxHeight: .infinity)
        .background(WindowReader { window in
            if model.taskWindow !== window { model.taskWindow = window }
        })
        .onAppear {
            DispatchQueue.main.async { model.taskWindow?.makeKeyAndOrderFront(nil) }
        }
        // "Open" on an already open window (another task, or the same one from the main window) brings it forward.
        .onChange(of: model.taskWindowRequest) { _, _ in
            DispatchQueue.main.async {
                if let w = model.taskWindow, w.isVisible { w.makeKeyAndOrderFront(nil) }
            }
        }
        .sheet(isPresented: Binding(get: { model.newTaskInTaskWindow && model.newTaskDraft != nil },
                                    set: { if !$0 { model.newTaskDraft = nil } })) {
            if let draft = model.newTaskDraft { NewTaskSheet(draft: draft) }
        }
        .modifier(TaskFlowSheets(host: .task))
        // Closing the window (button, ⌘W) is handled by `AppModel.taskWindowWillClose`: SwiftUI may deliver
        // onDisappear of a closed Window scene late, after the next item was already opened.
    }

    static let id = "task"
}

/// The task window: left — title, text, files; right — session, settings, dates; bottom — history and changes.
/// Status, launch and file actions live in the window toolbar.
struct TaskWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let taskID: String

    var body: some View {
        if let task = model.task(taskID), let project = model.project(task.projectID) {
            VSplitView {
                HSplitView {
                    TaskMainPane(task: task, project: project)
                        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                        .layoutPriority(1)
                    TaskMetaPane(task: task, project: project)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 400, maxHeight: .infinity)
                }
                .frame(minHeight: 300, idealHeight: 500)
                TaskActivityPane(task: task)
                    .frame(minHeight: 160, idealHeight: 280, maxHeight: .infinity)
            }
            .navigationTitle("\(task.taskID) · \(task.title.isEmpty ? "Без заголовка" : task.title)")
            .navigationSubtitle(project.name)
            .toolbar { TaskToolbar(task: task) }
        } else {
            ContentUnavailableView {
                Label("Задача не найдена", systemImage: "questionmark.folder")
            } description: {
                Text("Папку задачи удалили или переименовали.")
            } actions: {
                Button("Закрыть окно") { dismissWindow(id: TaskWindowScene.id) }
            }
            .navigationTitle("Задача")
        }
    }
}

/// Toolbar of the task window: the one place for status, launch and the task's folders.
private struct TaskToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    let task: ArtelTask

    var body: some ToolbarContent {
        let current = model.task(task.id) ?? task
        let blocker = model.launchBlocker(for: current)
        let session = model.activeSession(for: current)
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(TaskStatus.allCases) { s in
                    Button { model.setStatus(current, s) } label: {
                        if s == current.status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            } label: {
                Label(current.status.title, systemImage: current.status.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(current.status.color)
            }
            .help("Статус задачи")
            .accessibilityLabel("Статус: \(current.status.title)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.openInEditor(projectID: current.projectID, root: model.codeRoot(for: current)) } label: {
                Label("Код", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help(current.worktree != nil ? "Открыть worktree задачи в редакторе кода" : "Открыть проект в редакторе кода")
            Button { NSWorkspace.shared.open(current.directory) } label: { Label("Папка задачи", systemImage: "folder") }
                .help("Папка задачи: task.md, вложения, логи")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            if let session {
                Button { model.focus(session.id) } label: {
                    Label("К сессии", systemImage: model.status(session.id).activity.symbol)
                        .labelStyle(.titleAndIcon)
                }
                .help("Перейти к сессии «\(session.name)» — \(model.status(session.id).activity.title)")
            } else {
                Button { model.requestLaunch(taskID: current.id, intoSession: nil) } label: {
                    Label("Запустить", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(blocker != nil)
                .help(blocker ?? "Запустить в новой сессии (⌘R). Или перетащите задачу в рабочую область.")
            }
        }
    }
}

/// The new-task sheet: title, project, agent, model and text. "Создать" writes the task and opens its window.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: TaskDraft
    @State private var confirmDiscard = false
    @FocusState private var titleFocused: Bool
    private let initial: TaskDraft

    init(draft: TaskDraft) {
        _draft = State(initialValue: draft)
        initial = draft
    }

    var body: some View {
        let project = model.project(draft.projectID)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Заголовок задачи", text: $draft.title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit(create)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                MetaRow("Проект") {
                    Picker("Проект", selection: Binding(get: { draft.projectID }, set: { id in
                        guard let new = model.project(id) else { return }
                        draft.switchProject(to: new, from: model.project(draft.projectID))
                    })) {
                        ForEach(model.state.projects) { p in
                            Label { Text(p.name) } icon: { Image(nsImage: ProjectPalette.swatchImage(p.colorIndex)) }
                                .tag(p.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TaskSettingsFields(model_: $draft.model, agentID: $draft.agent)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider()
            HStack(spacing: 10) {
                Text("Текст задачи — это промпт агенту").font(.caption).foregroundStyle(.secondary)
                Spacer()
                MarkdownModePicker()
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            MarkdownPane(text: $draft.body)
                .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Text("Файлы, вложения и история — после создания.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Создать", action: create)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .disabled(!draft.canCreate || project == nil)
                    .help(draft.canCreate ? "Создать задачу (⌘⏎)" : "Введите заголовок")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity, minHeight: 460, idealHeight: 600, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .interactiveDismissDisabled()
        // Errors (e.g. creation failed) show over this sheet: the window's own alerts yield to it.
        .modifier(TaskFlowSheets(host: .newTask))
        .onAppear { titleFocused = true }
        .confirmationDialog("Отменить новую задачу?", isPresented: $confirmDiscard) {
            Button("Отменить задачу", role: .destructive) { model.newTaskDraft = nil }
            Button("Продолжить редактирование", role: .cancel) {}
        } message: {
            Text("Заголовок, текст и настройки не сохранятся.")
        }
    }

    private func create() {
        guard draft.canCreate else { return }
        model.createTask(draft)
    }

    private func cancel() {
        if draft != initial { confirmDiscard = true } else { model.newTaskDraft = nil }
    }
}

extension AppModel {
    /// Binding to a task field that writes through `updateTask`.
    func taskBinding<T>(_ task: ArtelTask, _ keyPath: WritableKeyPath<ArtelTask, T>) -> Binding<T> {
        Binding(get: { (self.task(task.id) ?? task)[keyPath: keyPath] },
                set: { value in
                    guard var t = self.task(task.id) else { return }
                    t[keyPath: keyPath] = value
                    self.updateTask(t)
                })
    }

    func openTask(_ id: String) {
        selectedTaskID = id
        openedNoTaskID = nil
        if openedTaskID != id { openedHistoryModified = nil }
        openedTaskID = id
        taskWindowRequest += 1
    }
}

// MARK: - Top left: title · text · files

private struct TaskMainPane: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask
    let project: Project
    @State private var insertion: String?

    var body: some View {
        let current = model.task(task.id) ?? task
        VStack(alignment: .leading, spacing: 0) {
            TextField("Заголовок", text: model.taskBinding(task, \.title), axis: .vertical)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 10) {
                Text("Текст задачи — это промпт агенту").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Group {
                    Button { insertProjectFile() } label: { Label("Файл проекта", systemImage: "at") }
                        .help("Вставить ссылку @путь на файл проекта")
                    Button { attachFile() } label: { Label("Прикрепить", systemImage: "paperclip") }
                        .help("Скопировать файл или скриншот в задачу и вставить ссылку")
                }
                .buttonStyle(.borderless)
                MarkdownModePicker()
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            MarkdownPane(text: model.taskBinding(task, \.body), insertion: $insertion,
                         referencesForDrop: { urls in references(urls, current) },
                         openLink: { open($0, current) })
                .frame(maxHeight: .infinity)
            Divider()
            TaskFilesSection(task: current, project: project) { refs in
                insertion = "\n" + refs.joined(separator: "\n")
            }
        }
    }

    private func references(_ urls: [URL], _ task: ArtelTask) -> [String] {
        urls.compactMap { url in
            url.isFileURL ? try? TaskStore.reference(for: url, project: project, task: task) : url.absoluteString
        }
    }

    private func open(_ url: URL, _ task: ArtelTask) {
        if let path = MarkdownPreview.docPath(url) {
            model.openTaskFile(path, task: task)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func insertProjectFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = project.url
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Вставить"
        guard panel.runModal() == .OK else { return }
        insertion = panel.urls.compactMap { try? TaskStore.reference(for: $0, project: project, task: task) }.joined(separator: " ")
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "Прикрепить"
        guard panel.runModal() == .OK else { return }
        insertion = "\n" + panel.urls.compactMap { try? TaskStore.attach($0, to: task) }.joined(separator: "\n")
        model.attachmentsVersion += 1
    }
}

extension AppModel {
    /// A path referenced by a task: relative to the task folder (attachments/…), the worktree or the project.
    func resolveTaskFile(_ path: String, task: ArtelTask) -> URL? {
        if path.hasPrefix("/") { return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil }
        var roots = [task.directory]
        if let wt = task.worktree { roots.append(URL(fileURLWithPath: wt)) }
        if let p = project(task.projectID) { roots.append(p.url) }
        return roots.lazy.map { $0.appendingPathComponent(path) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func openTaskFile(_ path: String, task: ArtelTask) {
        guard let url = resolveTaskFile(path, task: task) else {
            errorMessage = "Файл \(path) не найден"
            return
        }
        let textLike = ["md", "txt", "swift", "go", "py", "ts", "js", "json", "yaml", "yml", "toml", "rs", "kt", "java"]
        if textLike.contains(url.pathExtension.lowercased()) || url.hasDirectoryPath {
            openInEditor(projectID: task.projectID, root: codeRoot(for: task), files: [url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Files of the task: project files referenced in the text and copied attachments. Drop files here to add them.
private struct TaskFilesSection: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask
    let project: Project
    let insert: ([String]) -> Void
    @State private var targeted = false
    /// Read on appear and after attach / remove / drop — not on every keystroke in the editor above.
    @State private var attachments: [URL] = []

    var body: some View {
        let refs = ProjectDocs.linkedPaths(in: task.body).filter { !$0.hasPrefix("attachments/") }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Файлы").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(refs.count + attachments.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text(targeted ? "Отпустите, чтобы добавить" : "Перетащите файлы сюда или в текст")
                    .font(.caption2).foregroundStyle(targeted ? Color.accentColor : .secondary)
            }
            if refs.isEmpty && attachments.isEmpty {
                Text("Нет файлов. Файлы проекта добавляются ссылкой @путь, остальные копируются в attachments/.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(refs, id: \.self) { path in
                            FileChip(name: path, url: model.resolveTaskFile(path, task: task), symbol: "at") {
                                model.openTaskFile(path, task: task)
                            }
                        }
                        ForEach(attachments, id: \.self) { url in
                            FileChip(name: url.lastPathComponent, url: url, symbol: "paperclip") {
                                NSWorkspace.shared.open(url)
                            }
                            .contextMenu {
                                Button("Удалить вложение", role: .destructive) {
                                    try? FileManager.default.removeItem(at: url)
                                    loadAttachments()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 64)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            let refs = urls.compactMap { url in
                url.isFileURL ? try? TaskStore.reference(for: url, project: project, task: task) : url.absoluteString
            }
            guard !refs.isEmpty else { return false }
            insert(refs)
            loadAttachments()
            return true
        } isTargeted: { targeted = $0 }
        .onAppear(perform: loadAttachments)
        .onChange(of: model.attachmentsVersion) { _, _ in loadAttachments() }
        .onChange(of: task.body) { old, new in
            // A drop into the editor copies files into attachments/: its reference shows up in the text.
            if new.count > old.count, new.contains("attachments/") { loadAttachments() }
        }
    }

    private func loadAttachments() {
        let fresh = ((try? FileManager.default.contentsOfDirectory(at: task.attachmentsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if fresh != attachments { attachments = fresh }
    }
}

private struct FileChip: View {
    let name: String
    let url: URL?
    let symbol: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "questionmark.square.dashed").foregroundStyle(.red)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 260)
        .help(url?.path ?? "Файл не найден")
        .contextMenu {
            if let url { Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
    }
}

// MARK: - Right: session · settings · dates

private struct TaskMetaPane: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask
    let project: Project

    var body: some View {
        let current = model.task(task.id) ?? task
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sessionBlock(current)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    MetaRow("Проект") {
                        HStack(spacing: 6) {
                            ProjectBadge(project: project, size: 14)
                            Text(project.name).lineLimit(1)
                        }
                    }
                    TaskSettingsFields(model_: model.taskBinding(task, \.model),
                                       agentID: model.taskBinding(task, \.agent))
                }
                .controlSize(.small)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    if let branch = current.branch {
                        MetaRow("Worktree") {
                            Text(branch).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                                .help(current.worktree ?? "")
                        }
                        MetaRow("База") { Text(model.baseBranch(for: project)).font(.caption.monospaced()) }
                    } else {
                        MetaRow("Рабочая копия") { Text("папка проекта").foregroundStyle(.secondary) }
                    }
                    MetaRow("Создана") { RelativeDate(date: current.created) }
                    MetaRow("Изменена") { RelativeDate(date: current.updated) }
                }
                .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    /// The task's session: where it runs, or why it can't be launched right now.
    @ViewBuilder
    private func sessionBlock(_ task: ArtelTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Сессия").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let s = model.activeSession(for: task) {
                let activity = model.status(s.id).activity
                HStack(spacing: 8) {
                    ActivityCapsule(activity: activity)
                    Text(s.name).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Button("Перейти к сессии") { model.focus(s.id) }
                    .controlSize(.small)
            } else if model.launchingTasks.contains(task.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Запускается…").foregroundStyle(.secondary)
                }
            } else if let blocker = model.launchBlocker(for: task) {
                Label(blocker, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Не запущена. Кнопка «Запустить» в тулбаре (⌘R) или перетащите задачу в рабочую область.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "3 ч назад", with the full date in the tooltip.
struct RelativeDate: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named))
            .help(date.formatted(date: .long, time: .shortened))
    }
}

// MARK: - Bottom: history · changes

private struct TaskActivityPane: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask
    @State private var tab = "history"

    var body: some View {
        let current = model.task(task.id) ?? task
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if current.worktree != nil {
                    Picker("Раздел", selection: $tab) {
                        Text("История").tag("history")
                        Text("Изменения").tag("diff")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text("История").font(.headline)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Divider()
            if tab == "diff" && current.worktree != nil {
                TaskDiffView(task: current).id(task.id)
            } else {
                TaskTimeline(task: current)
            }
        }
    }
}

/// History: creation, status changes, launches (and events of the old workflow in older tasks).
/// Reloaded on `historyVersion`: the model bumps it on its own writes and when history.jsonl changes on disk.
private struct TaskTimeline: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask
    @State private var entries: [TaskHistoryEntry] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                        HistoryRow(entry: entry) { model.openTaskFile($0, task: task) }.id(i)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: entries.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            .onAppear { proxy.scrollTo(entries.count - 1, anchor: .bottom) }
        }
        .onAppear(perform: load)
        .onChange(of: model.historyVersion) { _, _ in load() }
    }

    private func load() {
        let fresh = TaskHistory.timeline(for: model.task(task.id) ?? task)
        if fresh != entries { entries = fresh }
    }
}

private struct HistoryRow: View {
    let entry: TaskHistoryEntry
    let openFile: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.actor.title).font(.caption.weight(.semibold))
                    RelativeDate(date: entry.date).font(.caption2).foregroundStyle(.tertiary)
                }
                content
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .status:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let from = entry.from {
                        StatusDot(status: from)
                        Text(from.title)
                        Image(systemName: "arrow.right").font(.caption2)
                    }
                    if let to = entry.to {
                        StatusDot(status: to)
                        Text(to.title).fontWeight(.medium)
                    }
                }
                .font(.callout)
                if !entry.text.isEmpty { Text(entry.text).font(.callout).foregroundStyle(.secondary) }
            }
        case .comment:
            MarkdownPreview(text: entry.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
        case .artifact:
            HStack(spacing: 4) {
                Text(entry.text)
                if let file = entry.file {
                    Button("открыть") { openFile(file) }.buttonStyle(.link)
                }
            }
            .font(.callout)
        default:
            Text(entry.text).font(.callout)
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .created: "plus.circle"
        case .status: "arrow.triangle.swap"
        case .comment: "text.bubble"
        case .launch: "play.circle"
        case .artifact: "doc.text"
        case .merge: "arrow.triangle.merge"
        case .conflict: "exclamationmark.triangle"
        case .note: "info.circle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .comment: .orange
        case .conflict: .red
        case .merge: .green
        case .launch: .blue
        default: .secondary
        }
    }
}

// MARK: - Dialogs that can be opened from the main window, the task window or the new-task sheet

/// Launch / done / editor-choice dialogs and error alerts. Attached to every window that can host them;
/// exactly one host is active: the new-task sheet while it's open, else the window the operator works in.
struct TaskFlowSheets: ViewModifier {
    enum Host { case main, task, newTask }

    @Environment(AppModel.self) private var model
    let host: Host

    func body(content: Content) -> some View {
        let active: Bool = {
            // The new-task sheet covers its window: dialogs go on top of it.
            if model.newTaskDraft != nil { return host == .newTask }
            return host == (model.flowHostIsTask ? .task : .main)
        }()
        content
            .sheet(item: gate(\.taskLaunch, active)) { TaskLaunchSheet(request: $0) }
            .sheet(item: gate(\.doneRequest, active)) { DoneSheet(request: $0) }
            .sheet(item: gate(\.editorRequest, active)) { EditorChoiceSheet(request: $0) }
            .alert("Artel", isPresented: Binding(get: { active && model.errorMessage != nil },
                                                set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onChange(of: model.hasFlowDialog) { _, open in
                if !open { model.syncFlowHost() }
            }
    }

    private func gate<T>(_ keyPath: ReferenceWritableKeyPath<AppModel, T?>, _ active: Bool) -> Binding<T?> {
        Binding(get: { active ? model[keyPath: keyPath] : nil },
                set: { model[keyPath: keyPath] = $0 })
    }
}
