import ArtelCore
import AppKit
import SwiftUI

// The trees of the tool panel, JetBrains style: project rows with a chevron and a coloured folder, collapsible
// groups ("Sessions 4", "Tasks 1") and one-line rows with the time since their last change.

/// Projects and their groups of sessions and tasks, in two flavours:
/// - `.agentSessions` (Workspace): Sessions (live ones by latest activity, then the archived ones) and Tasks (open
///   tasks without a live session; a task's running session is in Sessions), filtered by `search`;
/// - `.tasks` (Tasks): "Waiting for You" on top, then per project its tasks under the board's search and filters,
///   and its sessions without a task with their archives.
/// Five rows per group until "Show more…". A click on a session goes to its terminal, a click on a task selects it;
/// a double click or ⏎ opens a task or an archive, ↑/↓ move the selection.
struct ProjectTree: View {
    enum Mode { case agentSessions, tasks }

    static let showTasksKey = "agentSessions.showTasks"
    static let showArchivesKey = "agentSessions.showArchives"
    /// Collapsed projects (UUIDs, comma-separated), shared by both trees.
    static let collapsedKey = "sidebar.collapsedProjects"
    /// Collapsed groups ("<project id>/sessions", "tasks:<project id>/tasks", …), newline-separated.
    static let collapsedGroupsKey = "agentSessions.collapsedGroups"
    static let visibleRows = 5

    @Environment(AppModel.self) private var model
    var mode: Mode
    /// The name filter of the agent sessions panel (the Tasks tree uses the board's search).
    var search: String = ""
    @AppStorage(showTasksKey) private var showTasks = true
    @AppStorage(showArchivesKey) private var showArchives = true
    @AppStorage(collapsedKey) private var collapsedRaw = ""
    @AppStorage(collapsedGroupsKey) private var collapsedGroupsRaw = ""
    /// Groups showing all their rows.
    @State private var showingAll: Set<String> = []
    @State private var selection: SidebarItem?
    @FocusState private var focused: Bool

    private struct TreeGroup {
        let key: String
        let title: String
        let items: [TreeItem]
    }

    private struct ProjectSection: Identifiable {
        let project: Project
        let groups: [TreeGroup]
        var id: UUID { project.id }
        var isEmpty: Bool { groups.allSatisfy(\.items.isEmpty) }
    }

    // MARK: Data

    private var searching: Bool {
        switch mode {
        case .agentSessions: !search.trimmingCharacters(in: .whitespaces).isEmpty
        case .tasks: !model.taskFilter.isDefault
        }
    }

    /// Group keys of the Tasks tree get their own prefix: its groups hold other rows than the workspace's.
    private func groupKey(_ project: Project, _ name: String) -> String {
        mode == .tasks ? "tasks:\(project.id)/\(name)" : "\(project.id)/\(name)"
    }

    private var topGroup: TreeGroup? {
        guard mode == .tasks else { return nil }
        let waiting = model.attentionSessions.map { TreeItem.session($0, model.task(for: $0)) }
        return TreeGroup(key: "tasks:waiting", title: "Waiting for You", items: waiting)
    }

    private var sections: [ProjectSection] {
        switch mode {
        case .agentSessions:
            return model.state.projects.map { project in
                ProjectSection(project: project, groups: [
                    TreeGroup(key: groupKey(project, "sessions"), title: "Sessions", items: sessionRows(of: project)),
                    TreeGroup(key: groupKey(project, "tasks"), title: "Tasks", items: openTaskRows(of: project)),
                ])
            }
        case .tasks:
            let only = model.sidebarFilter.projects
            return model.state.projects.filter { only.isEmpty || only.contains($0.id) }.map { project in
                let tasks = model.visibleTasks(of: project).map { TreeItem.task($0) }
                let loose = model.sessions(of: project).filter { $0.taskID == nil }
                    .sorted { model.status($0.id).since > model.status($1.id).since }
                    .map { TreeItem.session($0, nil) }
                let archives = model.visibleNoTasks(of: project).map { TreeItem.archive($0) }
                return ProjectSection(project: project, groups: [
                    TreeGroup(key: groupKey(project, "tasks"), title: "Tasks", items: tasks),
                    TreeGroup(key: groupKey(project, "sessions"), title: "Sessions", items: loose + archives),
                ])
            }
        }
    }

    /// Live sessions (newest activity first), then the archived ones.
    private func sessionRows(of project: Project) -> [TreeItem] {
        let live = model.sessions(of: project)
            .sorted { model.status($0.id).since > model.status($1.id).since }
            .map { TreeItem.session($0, model.task(for: $0)) }
        let archives = showArchives ? model.noTasks(of: project).map { TreeItem.archive($0) } : []
        return filtered(live + archives)
    }

    /// Open tasks without a live session, newest first.
    private func openTaskRows(of project: Project) -> [TreeItem] {
        guard showTasks else { return [] }
        return filtered(model.tasks
            .filter { $0.projectID == project.id && !$0.status.isClosed && model.activeSession(for: $0) == nil }
            .sorted { $0.updated > $1.updated }
            .map { TreeItem.task($0) })
    }

    private func filtered(_ items: [TreeItem]) -> [TreeItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    // MARK: Collapsing

    private var collapsed: Set<UUID> {
        Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func setCollapsed(_ id: UUID, _ value: Bool) {
        var set = collapsed
        if value { set.insert(id) } else { set.remove(id) }
        withAnimation(.easeOut(duration: 0.12)) { collapsedRaw = set.map(\.uuidString).sorted().joined(separator: ",") }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: "\n").map(String.init))
    }

    private func toggleGroup(_ key: String) {
        var set = collapsedGroups
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.easeOut(duration: 0.12)) { collapsedGroupsRaw = set.sorted().joined(separator: "\n") }
    }

    /// A search shows its matches even in a collapsed group.
    private func isCollapsed(_ group: TreeGroup) -> Bool {
        collapsedGroups.contains(group.key) && !searching
    }

    private func shownItems(_ group: TreeGroup) -> [TreeItem] {
        if isCollapsed(group) { return [] }
        let all = showingAll.contains(group.key) || searching
        return all ? group.items : Array(group.items.prefix(Self.visibleRows))
    }

    /// The rows on screen, top to bottom: what ↑/↓ walk through.
    private func visibleKeys(top: TreeGroup?, sections: [ProjectSection]) -> [SidebarItem] {
        var keys = top.map(shownItems)?.map(\.key) ?? []
        for section in sections where !collapsed.contains(section.project.id) {
            for group in section.groups { keys += shownItems(group).map(\.key) }
        }
        return keys
    }

    // MARK: Views

    var body: some View {
        let top = topGroup
        let sections = sections
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let top, !top.items.isEmpty {
                    group(top, indent: 0)
                }
                ForEach(sections) { section in
                    let project = section.project
                    let isCollapsed = collapsed.contains(project.id)
                    let counts = section.groups.map(\.items.count)
                    ProjectTreeRow(project: project, collapsed: isCollapsed,
                                   summary: summary(section),
                                   current: model.currentProject?.id == project.id,
                                   toggle: { setCollapsed(project.id, !isCollapsed) })
                        .accessibilityValue(counts.map(String.init).joined(separator: ", "))
                    if !isCollapsed {
                        if section.isEmpty {
                            Text(emptyText)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 30)
                                .frame(height: 26)
                        }
                        ForEach(section.groups, id: \.key) { group($0, indent: 1) }
                    }
                }
                if model.state.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Projects").font(.headline)
                        Text("Add a project folder or drag one here from Finder.").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1, in: visibleKeys(top: top, sections: sections)) }
        .onKeyPress(.upArrow) { move(-1, in: visibleKeys(top: top, sections: sections)) }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            open(selection)
            return .handled
        }
        .modifier(FolderDropModifier())
        .onAppear {
            if mode == .tasks, let id = model.selectedTaskID { selection = .task(id) }
        }
        // Selection made elsewhere (the board, session cards) shows up here.
        .onChange(of: model.selectedTaskID) { _, id in
            if mode == .tasks, let id, selection != .task(id) { selection = .task(id) }
        }
        .onChange(of: model.focusedSessionID) { _, id in
            guard let id, selection != .session(id) else { return }
            // In the Tasks tree a task's session has no row of its own (unless it waits): highlight the task.
            if mode == .tasks, let record = model.record(id), let task = model.task(for: record),
               !model.attentionSessions.contains(where: { $0.id == id }) {
                selection = .task(task.id)
            } else {
                selection = .session(id)
            }
        }
    }

    private var emptyText: String {
        switch mode {
        case .agentSessions: searching ? "Nothing matches" : "No sessions or tasks"
        case .tasks: searching ? "No tasks match the filters" : "No tasks"
        }
    }

    /// "2 sessions · 3 tasks", shown next to a collapsed project.
    private func summary(_ section: ProjectSection) -> String {
        section.groups.compactMap { group in
            // Live sessions only: archives are not sessions any more.
            let n = group.items.filter { if case .archive = $0 { false } else { true } }.count
            guard n > 0 else { return nil }
            let noun = group.title.lowercased()
            return "\(n) \(n == 1 ? String(noun.dropLast()) : noun)"
        }
        .joined(separator: " · ")
    }

    /// A titled group of rows; empty groups are left out. `indent` 1 = under a project.
    @ViewBuilder private func group(_ group: TreeGroup, indent: Int) -> some View {
        if !group.items.isEmpty {
            let collapsedNow = isCollapsed(group)
            GroupHeader(title: group.title, count: group.items.count, collapsed: collapsedNow,
                        leading: indent == 0 ? 0 : 12, toggle: { toggleGroup(group.key) })
            if !collapsedNow {
                ForEach(shownItems(group)) { item in
                    TreeItemRow(item: item, selected: selection == item.key, leading: indent == 0 ? 28 : 40,
                                select: { select(item.key, byMouse: true) }, open: { open(item.key) })
                }
                if group.items.count > Self.visibleRows && !searching {
                    let all = showingAll.contains(group.key)
                    Button(all ? "Show less" : "Show more…") {
                        if all { showingAll.remove(group.key) } else { showingAll.insert(group.key) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, indent == 0 ? 52 : 64)
                    .frame(height: 26)
                }
            }
        }
    }

    private func move(_ delta: Int, in keys: [SidebarItem]) -> KeyPress.Result {
        guard !keys.isEmpty else { return .ignored }
        let index = selection.flatMap { keys.firstIndex(of: $0) }.map { $0 + delta } ?? (delta > 0 ? 0 : keys.count - 1)
        select(keys[min(max(index, 0), keys.count - 1)], byMouse: false)
        return .handled
    }

    /// A click on a session goes to its terminal; arrow keys only move the highlight (and focus the session).
    private func select(_ key: SidebarItem, byMouse: Bool) {
        selection = key
        switch key {
        case .session(let id):
            model.focus(id, takeKeyboard: byMouse)
        case .task(let id):
            model.selectedTaskID = id
            focused = true
        case .archive:
            focused = true
        }
    }

    private func open(_ key: SidebarItem) {
        switch key {
        case .session(let id): model.focus(id)
        case .task(let id): model.openTask(id)
        case .archive(let id): model.openNoTask(id)
        }
    }
}

enum TreeItem: Identifiable {
    case session(SessionRecord, ArtelTask?)
    case task(ArtelTask)
    case archive(ArtelTask)

    var key: SidebarItem {
        switch self {
        case .session(let r, _): .session(r.id)
        case .task(let t): .task(t.id)
        case .archive(let t): .archive(t.id)
        }
    }

    var id: SidebarItem { key }

    var title: String {
        switch self {
        case .session(let r, let task): task.map { "\($0.taskID) \($0.title)" } ?? r.name
        case .task(let t): "\(t.taskID) \(t.title)"
        case .archive(let t): t.title
        }
    }
}

/// "Sessions 4" / "Tasks 1" header of a group: a click collapses or expands the group.
private struct GroupHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    var leading: CGFloat = 12
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                Text(title)
                Text("\(count)").monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, leading)
            .padding(.top, 6)
            .frame(height: 24, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

/// A project's folder icon (or its emoji) in the project's colour.
struct ProjectFolderIcon: View {
    let project: Project
    var filled = true

    var body: some View {
        Group {
            if let icon = project.icon {
                Text(icon).font(.system(size: 14))
            } else {
                Image(systemName: filled ? "folder.fill" : "folder")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(ProjectPalette.color(project.colorIndex))
            }
        }
        .frame(width: 18)
    }
}

/// A project row: the chevron, the folder, the name (with a summary while collapsed), commit and "+" on hover.
private struct ProjectTreeRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let collapsed: Bool
    let summary: String
    let current: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
            ProjectFolderIcon(project: project, filled: !collapsed)
            Text(project.name).lineLimit(1)
            if collapsed {
                // Expanded, the groups show their own counts.
                Text(summary).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.artelDirty.contains(project.id) {
                Button { model.requestCommit(projectID: project.id) } label: {
                    Label("Commit .artel", systemImage: "arrow.up.doc").foregroundStyle(.orange)
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("There are uncommitted changes in .artel/. Commit them (⌥⌘S)")
            }
            Button { model.newSessionRequest = NewSessionRequest(projectID: project.id) } label: {
                Label("New Session", systemImage: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("New session in \(project.name)")
            .opacity(hovering ? 1 : 0)
            .disabled(!model.isReady)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(current ? Islands.selection : hovering ? Islands.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: toggle)
        .onTapGesture { model.selectCurrentProject(project.id) }
        .help(project.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: collapsed ? "Expand" : "Collapse", toggle)
        .contextMenu {
            Button(collapsed ? "Expand" : "Collapse", action: toggle)
            Divider()
            ProjectMenu(project: project)
        }
    }
}

/// Context menu items of a project row.
struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
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

/// A session, task or archive in the tree: icon, title, the time since its last change; ⋮ on hover.
private struct TreeItemRow: View {
    @Environment(AppModel.self) private var model
    let item: TreeItem
    let selected: Bool
    var leading: CGFloat = 40
    let select: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            title
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hovering {
                Menu { SidebarItemMenu(item: item.key) } label: {
                    Label("More", systemImage: "ellipsis").rotationEffect(.degrees(90))
                }
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle(size: 20))
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                badges
                if let date {
                    CompactSince(date: date).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Islands.selection : hovering ? Islands.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .contextMenu { SidebarItemMenu(item: item.key) }
        .modifier(TaskDragModifier(task: draggableTask))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open", open)
    }

    /// A task's id is dimmed: the title is what the eye looks for.
    private var title: Text {
        switch item {
        case .task(let t), .session(_, let t?):
            Text("\(Text(t.taskID).foregroundStyle(.secondary)) \(t.title)")
        case .session(let r, nil):
            Text(r.name)
        case .archive(let t):
            Text(t.title).foregroundStyle(.secondary)
        }
    }

    /// A task's own branch and the state of its running session.
    @ViewBuilder private var badges: some View {
        if case .task(let task) = item {
            if task.worktree != nil {
                Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                    .help("Own branch: \(task.branch ?? "")")
                    .accessibilityHidden(true)
            }
            if let session = model.activeSession(for: task) {
                let activity = model.status(session.id).activity
                Image(systemName: activity.symbol).foregroundStyle(activity.color)
                    .help("Session: \(activity.title)")
            } else if model.launchingTasks.contains(task.id) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var draggableTask: ArtelTask? {
        if case .task(let t) = item { return t }
        return nil
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .session(let r, _):
            let activity = model.status(r.id).activity
            Image(systemName: activity == .working ? "asterisk" : activity.symbol)
                .foregroundStyle(activity == .working ? Color.orange : activity.color)
                .symbolEffect(.pulse, isActive: activity == .working)
        case .task(let t):
            StatusDot(status: t.status)
        case .archive:
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary)
        }
    }

    private var date: Date? {
        switch item {
        case .session(let r, _): model.status(r.id).since
        case .task(let t), .archive(let t): t.updated
        }
    }

    private var help: String {
        switch item {
        case .session(let r, _): "\(r.name) · \(model.status(r.id).activity.title). Click to go to the terminal"
        case .task(let t):
            model.launchBlocker(for: t).map { "\($0). Double-click or press ⏎ to open" }
                ?? "Double-click or press ⏎ to open. Drag to the workspace to launch"
        case .archive: "Archived session. Double-click or press ⏎ to see its overview and files"
        }
    }
}

private struct TaskDragModifier: ViewModifier {
    let task: ArtelTask?

    func body(content: Content) -> some View {
        if let task { content.taskDragSource(task) } else { content }
    }
}

/// "now", "9m", "4h", "3d", refreshed periodically.
struct CompactSince: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(Self.format(ctx.date.timeIntervalSince(date)))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

// MARK: - Projects list

/// The Projects section's panel: one row per project (folder, name, open tasks and sessions); the selected one is
/// the project whose documentation the content shows.
struct ProjectsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.state.projects) { project in
                    ProjectListRow(project: project, selected: model.docsProjectID == project.id)
                }
                if model.state.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Projects").font(.headline)
                        Text("Add a project folder or drag one here from Finder.").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .modifier(FolderDropModifier())
    }
}

private struct ProjectListRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let open = model.tasks.filter { $0.projectID == project.id && !$0.status.isClosed }.count
        let sessions = model.sessions(of: project).count
        HStack(spacing: 6) {
            ProjectFolderIcon(project: project, filled: selected)
            Text(project.name).lineLimit(1)
            Spacer(minLength: 6)
            if model.artelDirty.contains(project.id) {
                Image(systemName: "arrow.up.doc").foregroundStyle(.orange)
                    .help("There are uncommitted changes in .artel/")
            }
            Text(summary(tasks: open, sessions: sessions))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Islands.selection : hovering ? Islands.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectCurrentProject(project.id) }
        .help(project.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(project.name), open tasks: \(open), sessions: \(sessions)")
        .contextMenu { ProjectMenu(project: project) }
    }

    /// "3 tasks · 1 session"; empty when there is neither.
    private func summary(tasks: Int, sessions: Int) -> String {
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks) \(tasks == 1 ? "task" : "tasks")") }
        if sessions > 0 { parts.append("\(sessions) \(sessions == 1 ? "session" : "sessions")") }
        return parts.joined(separator: " · ")
    }
}
