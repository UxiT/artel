import ArtelCore
import SwiftUI

/// Top-level sections in toolbar order (⌥⌘1…3 follow it).
enum AppSection: String, CaseIterable, Identifiable {
    case workspace, projects, tasks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .projects: "Проекты"
        case .tasks: "Задачи"
        }
    }
    var symbol: String {
        switch self {
        case .workspace: "rectangle.grid.2x2"
        case .projects: "folder"
        case .tasks: "rectangle.split.3x1"
        }
    }

    /// Accepts the old name of the workspace too (debug scripts).
    init?(name: String) {
        self.init(rawValue: name == "sessions" ? "workspace" : name)
    }

    static var shortcutsHelp: String {
        allCases.enumerated().map { "\($1.title) ⌥⌘\($0 + 1)" }.joined(separator: " · ")
    }
}

extension AppModel {
    /// Tasks for the board, one pass for all columns: the window filter minus its status part
    /// (statuses are the columns), newest first.
    func boardColumns() -> [TaskStatus: [ArtelTask]] {
        var filter = taskFilter
        filter.statuses = Set(TaskStatus.allCases)
        let projectIDs = Set(state.projects.map(\.id))
        let matching = tasks.filter { projectIDs.contains($0.projectID) && filter.matches($0) }
            .sorted { $0.updated > $1.updated }
        return Dictionary(grouping: matching, by: \.status)
    }
}

/// Kanban board: a flexible column per status. Click selects a card, double click or ⏎ opens it,
/// arrow keys move the selection, ⌥← / ⌥→ move the selected task to the neighbouring column.
struct TaskBoardView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedCard: String?

    var body: some View {
        let columns = model.boardColumns()
        GeometryReader { geo in
            let spacing = 12.0
            let count = Double(TaskStatus.allCases.count)
            let width = max(260, (geo.size.width - spacing * (count + 1)) / count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(TaskStatus.allCases) { status in
                        BoardColumn(status: status, tasks: columns[status] ?? [], focusedCard: $focusedCard)
                            .frame(width: width)
                    }
                }
                .padding(spacing)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if model.state.projects.isEmpty {
                ContentUnavailableView("Нет проектов", systemImage: "folder.badge.plus",
                                       description: Text("Добавьте проект (⇧⌘O), чтобы завести задачи."))
            }
        }
        .onChange(of: focusedCard) { _, id in
            if let id { model.selectedTaskID = id }
        }
        .onMoveCommand { direction in move(direction, columns: columns) }
    }

    private func move(_ direction: MoveCommandDirection, columns: [TaskStatus: [ArtelTask]]) {
        let statuses = TaskStatus.allCases
        guard let id = model.selectedTaskID, let task = model.task(id),
              let col = statuses.firstIndex(of: task.status) else {
            focusedCard = statuses.lazy.compactMap { columns[$0]?.first?.id }.first
            return
        }
        let list = columns[task.status] ?? []
        let row = list.firstIndex { $0.id == id } ?? 0
        let option = NSEvent.modifierFlags.contains(.option)
        switch direction {
        case .up:
            if row > 0 { focusedCard = list[row - 1].id }
        case .down:
            if row + 1 < list.count { focusedCard = list[row + 1].id }
        case .left, .right:
            let step = direction == .left ? -1 : 1
            let target = col + step
            guard target >= 0, target < statuses.count else { return }
            if option {
                // ⌥← / ⌥→: move the task itself (done with a worktree asks first).
                model.setStatus(task, statuses[target])
            } else if let other = columns[statuses[target]], !other.isEmpty {
                focusedCard = other[min(row, other.count - 1)].id
            }
        @unknown default:
            break
        }
    }
}

private struct BoardColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let status: TaskStatus
    let tasks: [ArtelTask]
    var focusedCard: FocusState<String?>.Binding
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(status: status)
                Text(status.title).font(.headline)
                Text("\(tasks.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { BoardCard(task: $0, focusedCard: focusedCard) }
                    if tasks.isEmpty {
                        Text(targeted ? "Отпустите, чтобы перенести" : "Пусто")
                            .font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.7)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : HairlineColor.border(contrast), lineWidth: targeted ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.title), задач: \(tasks.count)")
        // Drop a card here: the operator moves the task to this status (done with a worktree asks first).
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(DragPayload.taskID(from:)).first, let task = model.task(id),
                  task.status != status else { return false }
            model.setStatus(task, status)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct BoardCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let task: ArtelTask
    var focusedCard: FocusState<String?>.Binding

    var body: some View {
        let selected = model.selectedTaskID == task.id
        let project = model.project(task.projectID)
        let activity = model.activeSession(for: task).map { model.status($0.id).activity }
        let attention = activity?.needsAttention ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProjectBadge(project: project, size: 14)
                Text(task.taskID).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if task.worktree != nil {
                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                        .help("Своя ветка: \(task.branch ?? "")")
                }
                if model.launchingTasks.contains(task.id) {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(task.title).font(.body).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            if activity != nil || (model.state.projects.count > 1 && model.taskFilter.projects.count != 1) {
                HStack(spacing: 6) {
                    if let activity { ActivityCapsule(activity: activity) }
                    Spacer(minLength: 0)
                    if model.state.projects.count > 1, model.taskFilter.projects.count != 1, let project {
                        Text(project.name).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : attention ? activity!.color : HairlineColor.border(contrast),
                              lineWidth: selected || attention ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focused(focusedCard, equals: task.id)
        .focusEffectDisabled()
        // A click selects at once; a double click selects and opens.
        .simultaneousGesture(TapGesture().onEnded { select() })
        .onTapGesture(count: 2) { model.openTask(task.id) }
        .onKeyPress(.return) { model.openTask(task.id); return .handled }
        .onKeyPress(.space) { model.openTask(task.id); return .handled }
        .taskDragSource(task)
        .contextMenu {
            Button("Открыть задачу") { model.openTask(task.id) }
            Divider()
            TaskMenu(task: task)
        }
        .help("Двойной клик или ⏎ — открыть")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(task.taskID), \(task.title)")
        .accessibilityValue([project?.name, activity.map { "сессия: \($0.title)" }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction { model.openTask(task.id) }
        .accessibilityAction(named: "Запустить") { model.requestLaunch(taskID: task.id, intoSession: nil) }
    }

    private func select() {
        model.selectedTaskID = task.id
        focusedCard.wrappedValue = task.id
    }
}
