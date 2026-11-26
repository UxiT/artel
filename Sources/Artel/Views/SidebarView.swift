import ArtelCore
import AppKit
import SwiftUI

/// What a sidebar row stands for. Selecting a row only selects it; Return or a double click opens it.
enum SidebarItem: Hashable {
    case task(String)
    case session(String)
    case archive(String)
}

/// Context menu of a sidebar row.
struct SidebarItemMenu: View {
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
