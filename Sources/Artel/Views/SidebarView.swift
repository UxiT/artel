import ArtelCore
import AppKit
import SwiftUI

/// What a sidebar row stands for. Selecting a row only selects it; Return or a double click opens it.
enum SidebarItem: Hashable {
    case task(String)
    case session(String)
    case archive(String)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedNoTaskProjects: Set<UUID> = []
    @State private var selection: SidebarItem?
    /// Collapsed projects (UUIDs, comma-separated): their tasks, sessions and archives are hidden.
    @AppStorage("sidebar.collapsedProjects") private var collapsedRaw = ""

    private var collapsedProjects: Set<UUID> {
        Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjects.contains(id) },
            set: { expanded in
                var set = collapsedProjects
                if expanded { set.remove(id) } else { set.insert(id) }
                collapsedRaw = set.map(\.uuidString).sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        List(selection: Binding(get: { selection }, set: select)) {
            let waiting = model.attentionSessions
            if !waiting.isEmpty {
                Section("Waiting for You") {
                    ForEach(waiting) { SessionRow(record: $0, showProject: true).tag(SidebarItem.session($0.id)) }
                }
            }
            ForEach(model.state.projects) { project in
                let tasks = model.visibleTasks(of: project)
                let loose = model.sessions(of: project).filter { $0.taskID == nil }
                let archives = model.visibleNoTasks(of: project)
                if model.sidebarFilter.projects.isEmpty || model.sidebarFilter.projects.contains(project.id) {
                    Section(isExpanded: expansion(project.id)) {
                        ForEach(tasks) { TaskRow(task: $0).tag(SidebarItem.task($0.id)) }
                        if tasks.isEmpty {
                            Text(model.sidebarFilter.isDefault ? "No Tasks" : "No Tasks Match the Filters")
                                .font(.caption).foregroundStyle(.tertiary)
                                .selectionDisabled()
                        }
                        ForEach(loose) { SessionRow(record: $0, showProject: false).tag(SidebarItem.session($0.id)) }
                        if !archives.isEmpty {
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedNoTaskProjects.contains(project.id) },
                                set: { expanded in
                                    if expanded {
                                        expandedNoTaskProjects.insert(project.id)
                                    } else {
                                        expandedNoTaskProjects.remove(project.id)
                                    }
                                }
                            )) {
                                ForEach(archives) { NoTaskRow(task: $0).tag(SidebarItem.archive($0.id)) }
                            } label: {
                                Label("No Task", systemImage: "archivebox")
                                    .badge(archives.count)
                                    .foregroundStyle(.secondary)
                                    .help("Archives of sessions without a task are kept for 7 days")
                            }
                            .selectionDisabled()
                        }
                    } header: {
                        ProjectHeader(project: project, isExpanded: expansion(project.id),
                                      hiddenSessions: model.sessions(of: project).count)
                    }
                }
            }
            if model.state.projects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Projects").font(.headline)
                    Text("Add a project folder or drag one here from Finder.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Add Project…") { ProjectPicker.present(model) }
                }
                .padding(.vertical, 8)
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first { SidebarItemMenu(item: item) }
        } primaryAction: { items in
            if let item = items.first { open(item) }
        }
        .modifier(FolderDropModifier())
        .modifier(SolidBackgroundInSnapshots())
        .onAppear { if let id = model.selectedTaskID { selection = .task(id) } }
        // Selection made elsewhere (board, session cards) shows up here.
        .onChange(of: model.selectedTaskID) { _, id in
            if let id, selection != .task(id) { selection = .task(id) }
        }
        .onChange(of: model.focusedSessionID) { _, id in
            guard let id, selection != .session(id), let record = model.record(id) else { return }
            // A task's session has no row of its own (unless it waits): highlight the task.
            if let task = model.task(for: record), !model.attentionSessions.contains(where: { $0.id == id }) {
                selection = .task(task.id)
            } else {
                selection = .session(id)
            }
        }
    }

    private func select(_ item: SidebarItem?) {
        selection = item
        switch item {
        case .task(let id):
            model.selectedTaskID = id
        case .session(let id):
            // A click goes straight to the terminal; arrow keys only move the highlight.
            let byMouse = [.leftMouseDown, .leftMouseUp].contains(NSApp.currentEvent?.type)
            model.focus(id, takeKeyboard: byMouse)
        case .archive, nil:
            break
        }
    }

    private func open(_ item: SidebarItem) {
        switch item {
        case .task(let id): model.openTask(id)
        case .session(let id): model.focus(id)
        case .archive(let id): model.openNoTask(id)
        }
    }
}

/// Context menu of a sidebar row.
private struct SidebarItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        switch item {
        case .task(let id):
            if let task = model.task(id) {
                Button("Open Task") { model.openTask(id) }
                Divider()
                TaskMenu(task: task)
            }
        case .session(let id):
            if let record = model.record(id) { SessionMenu(record: record) }
        case .archive(let id):
            if let archive = model.noTask(id) {
                Button("Open Overview") { model.openNoTask(archive.id) }
                Button("Add to Board") { model.convertNoTask(archive) }
                Button("Show Log in Finder") { model.revealNoTaskLog(archive) }
                Button("Show Folder in Finder") { NSWorkspace.shared.open(archive.directory) }
            }
        }
    }
}

/// Projects section sidebar: the list of projects.
struct ProjectListSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.docsProjectID }, set: { id in
            guard id != model.docsProjectID else { return }
            model.docsProjectID = id
            model.docsPath = nil  // the project's docs home page
            model.docsSearch = ""
        })) {
            Section("Projects") {
                ForEach(model.state.projects) { project in
                    let open = model.tasks.filter { $0.projectID == project.id && !$0.status.isClosed }.count
                    let sessions = model.sessions(of: project).count
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                            Text("tasks: \(open) · sessions: \(sessions)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        ProjectBadge(project: project, size: 18)
                    }
                    .tag(project.id)
                    .help(project.path)
                    .accessibilityLabel("\(project.name), open tasks: \(open), sessions: \(sessions)")
                    .contextMenu {
                        Button("Project Settings…") { model.projectSettingsID = project.id }
                        Button("Open in Code Editor") { model.openInEditor(projectID: project.id, root: project.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                        Divider()
                        Button("Remove Project from Artel", role: .destructive) { model.removeProject(project) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { ProjectPicker.present(model) } label: { Label("Add Project", systemImage: "plus") }
                    .buttonStyle(.glass)
                    .help("Add a project (⇧⌘O), or drag a folder from Finder")
                Spacer()
            }
            .padding(10)
        }
        .modifier(FolderDropModifier())
        .modifier(SolidBackgroundInSnapshots())
    }
}

struct FilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Projects") {
                ForEach(model.state.projects) { p in
                    toggle(p.name, model.taskFilter.projects.contains(p.id)) {
                        model.taskFilter.projects.formSymmetricDifference([p.id])
                    }
                }
            }
            Section("Statuses") {
                ForEach(TaskStatus.allCases) { s in
                    toggle(s.title, model.taskFilter.statuses.contains(s)) {
                        model.taskFilter.statuses.formSymmetricDifference([s])
                    }
                }
            }
            Divider()
            Button("Show All Statuses") { model.taskFilter.statuses = Set(TaskStatus.allCases) }
            Button("Reset Filters") { model.taskFilter = TaskFilter(search: model.taskFilter.search) }
        } label: {
            Label("Filters", systemImage: model.taskFilter.isDefault ? "line.3.horizontal.decrease.circle"
                                                                    : "line.3.horizontal.decrease.circle.fill")
        }
        .help(model.taskFilter.isDefault ? "Filters: projects and statuses" : "Filters are on")
    }

    private func toggle(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask

    var body: some View {
        let session = model.activeSession(for: task)
        let activity = session.map { model.status($0.id).activity }
        let blocker = model.launchBlocker(for: task)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            StatusDot(status: task.status)
            Text("\(Text(task.taskID).font(.caption.monospaced()).foregroundStyle(.secondary))  \(task.title)")
                .lineLimit(2)
            Spacer(minLength: 4)
            if task.worktree != nil {
                Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                    .help("Own branch: \(task.branch ?? "")")
                    .accessibilityHidden(true)
            }
            if let activity {
                Image(systemName: activity.symbol)
                    .foregroundStyle(activity.color)
                    .help("Session: \(activity.title)")
            } else if model.launchingTasks.contains(task.id) {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .taskDragSource(task)
        .help(blocker.map { "\($0). Double-click or press ⏎ to open" }
              ?? "Double-click or press ⏎ to open. Drag to the workspace to launch")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.taskID), \(task.title)")
        .accessibilityValue([task.status.title, activity.map { "session: \($0.title)" }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: "Open") { model.openTask(task.id) }
    }
}

struct TaskMenu: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask

    var body: some View {
        Button("Launch in New Session…") { model.requestLaunch(taskID: task.id, intoSession: nil) }
            .disabled(model.launchBlocker(for: task) != nil)
        if let s = model.activeSession(for: task) {
            Button("Go to Session") { model.focus(s.id) }
        }
        Menu("Status") {
            ForEach(TaskStatus.allCases) { s in
                Button { model.setStatus(task, s) } label: {
                    if s == task.status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                }
            }
        }
        Divider()
        Button("Open Code in Editor") { model.openInEditor(projectID: task.projectID, root: model.codeRoot(for: task)) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([task.file]) }
    }
}

struct ProjectHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var isExpanded: Bool
    /// Sessions of the project, shown as a count while it is collapsed.
    var hiddenSessions = 0
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ProjectBadge(project: project, size: 14)
            // subheadline (11 pt on macOS) + 4 pt.
            Text(project.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            if !isExpanded && hiddenSessions > 0 {
                Text("\(hiddenSessions)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("Sessions in the collapsed project: \(hiddenSessions)")
            }
            Spacer()
            if model.artelDirty.contains(project.id) {
                Button { model.requestCommit(projectID: project.id) } label: {
                    Label("Commit .artel", systemImage: "arrow.up.doc").labelStyle(.iconOnly).foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("There are uncommitted changes in .artel/. Commit them (⌥⌘S)")
            }
            Button {
                model.newSessionRequest = NewSessionRequest(projectID: project.id)
            } label: { Label("New Session", systemImage: "terminal").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("New session without a task (\(AppShortcuts.newSessionWithoutTask.display))")
                .disabled(!model.isReady)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(!hovering)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "New Session") { model.newSessionRequest = NewSessionRequest(projectID: project.id) }
        .help(project.path)
        .contextMenu {
            Button(isExpanded ? "Collapse Project" : "Expand Project") { withAnimation { isExpanded.toggle() } }
            Divider()
            Button("New Session…") { model.newSessionRequest = NewSessionRequest(projectID: project.id) }
            Button("Commit Tasks (.artel)…") { model.requestCommit(projectID: project.id) }
            Button("Project Settings…") { model.projectSettingsID = project.id }
            Button("Documentation…") { model.openProjectDocs(project.id, path: nil) }
            Button("Open in Code Editor") { model.openInEditor(projectID: project.id, root: project.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Divider()
            Button("Remove Project from Artel", role: .destructive) { model.removeProject(project) }
        }
    }
}

struct NoTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text("Archive")
                    SinceText(date: task.updated)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { model.convertNoTask(task) } label: {
                Label("Add to Board", systemImage: "plus.square.on.square").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Create a numbered task and add it to the board")
        }
        .padding(.vertical, 2)
        .help("Double-click or press ⏎ to see the session overview and its files")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open Overview") { model.openNoTask(task.id) }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    let showProject: Bool

    var body: some View {
        let status = model.status(record.id)
        HStack(spacing: 8) {
            Image(systemName: status.activity.symbol)
                .foregroundStyle(status.activity.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).lineLimit(1)
                Group {
                    if showProject, let p = model.project(record.projectID) {
                        Text("\(p.name) · \(status.activity.title)")
                    } else {
                        Text(status.activity.title)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SinceText(date: status.since).font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Go to Session") { model.focus(record.id) }
    }
}

struct SessionMenu: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord

    var body: some View {
        Button(model.state.expandedSessionID == record.id ? "Collapse" : "Expand") { model.toggleExpanded(record.id) }
        Menu("Grid Size") {
            ForEach(1...3, id: \.self) { n in
                Button { model.resize(session: record.id, columnSpan: n, rowSpan: record.rowSpan) } label: {
                    let title = "Width: \(n) \(n == 1 ? "Column" : "Columns")"
                    if record.columnSpan == n { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            Divider()
            ForEach(1...2, id: \.self) { n in
                Button { model.resize(session: record.id, columnSpan: record.columnSpan, rowSpan: n) } label: {
                    let title = "Height: \(n) \(n == 1 ? "Row" : "Rows")"
                    if record.rowSpan == n { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            if record.columnSpan > 1 || record.rowSpan > 1 {
                Divider()
                Button("Reset Size") { model.resize(session: record.id, columnSpan: 1, rowSpan: 1) }
            }
        }
        if record.taskID == nil {
            Toggle("Keep in Archive", isOn: Binding(
                get: { model.record(record.id)?.archivesNoTask ?? record.archivesNoTask },
                set: { model.setArchivesNoTask($0, sessionID: record.id) }))
            if model.noTask(sessionID: record.id) != nil {
                Button("Add to Board as Task") { model.convertNoTask(sessionID: record.id) }
            }
        }
        if model.state.tabs.count > 1 {
            Menu("Move to Tab") {
                ForEach(model.state.tabs.filter { $0.id != (record.tabID ?? model.state.tabs.first?.id) }) { tab in
                    Button(tab.title) { model.move(session: record.id, toTab: tab.id) }
                }
            }
        }
        if model.status(record.id).activity == .exited {
            Button("Relaunch") { model.relaunch(record) }
        }
        Button("Open in Code Editor") {
            model.openInEditor(projectID: record.projectID, root: URL(fileURLWithPath: record.cwd))
        }
        Divider()
        Button("Stop…", role: .destructive) { model.sessionToStop = record }
    }
}

/// "5 min", refreshed periodically.
struct SinceText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            Text(Self.format(ctx.date.timeIntervalSince(date)))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        return "\(s / 86400) d"
    }
}

private struct SolidBackgroundInSnapshots: ViewModifier {
    func body(content: Content) -> some View {
        if DebugSnapshot.enabled {
            content.scrollContentBackground(.hidden).background(Color(nsColor: .windowBackgroundColor))
        } else {
            content
        }
    }
}
