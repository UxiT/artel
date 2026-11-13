import ArtelCore
import SwiftUI

/// Confirmation before a task goes to an agent: model, worktree, context of an existing session.
struct TaskLaunchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TaskLaunchRequest

    @State private var chosenModel: String?
    @State private var customModel = ""
    @State private var saveModel = true
    @State private var clearContext = true
    /// Last choice, offered again for the next task.
    @AppStorage("launch.useWorktree") private var useWorktree = false

    private let customTag = "__custom__"

    var body: some View {
        if let task = model.task(request.taskID) {
            let agent = model.agent(for: task)
            let target = request.sessionID.flatMap { model.record($0) }
            let otherTask = target.map { $0.taskID != task.taskID || $0.projectID != task.projectID } ?? false
            let needsModel = task.model == nil || task.model == ""
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Запуск \(task.taskID)").font(.title3.bold())
                    Text(task.title).foregroundStyle(.secondary)
                    Text(target.map { "В сессию «\($0.name)»" } ?? "В новую сессию")
                        .font(.callout)
                }

                Form {
                    if needsModel {
                        Picker("Модель", selection: $chosenModel) {
                            ForEach(agent.models) { m in Text(m.title).tag(m.id) }
                            Text("Другая…").tag(Optional(customTag))
                        }
                        if chosenModel == customTag {
                            TextField("Id модели", text: $customModel)
                        }
                        Toggle("Сохранить модель в задаче", isOn: $saveModel)
                    } else {
                        LabeledContent("Модель", value: task.model ?? "")
                    }

                    if let worktree = task.worktree {
                        LabeledContent("Worktree") {
                            Text(worktree).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                        }
                    } else {
                        Toggle("Отдельный git worktree", isOn: $useWorktree)
                        Text(useWorktree
                             ? "Агент работает в копии проекта на ветке \(WorktreeLayout.branch(for: task)). Слить её — вручную."
                             : "Агент работает прямо в рабочей копии проекта.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let target {
                        Toggle("Очистить контекст предыдущей сессии", isOn: otherTask ? .constant(true) : $clearContext)
                            .disabled(otherTask)
                        if otherTask {
                            Label(
                                "Сессия сейчас привязана к \(target.taskID.map { "задаче \($0)" } ?? "работе без задачи") (\(model.project(target.projectID)?.name ?? "")). Контекст будет очищен, агент перезапустится в рабочей директории задачи \(task.taskID).",
                                systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Запустить") {
                        let m: String? = needsModel ? (chosenModel == customTag ? customModel.trimmingCharacters(in: .whitespaces) : chosenModel) : task.model
                        model.launch(request, model: m, saveModel: needsModel && saveModel,
                                     clearContext: otherTask || clearContext, useWorktree: useWorktree)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsModel && chosenModel == customTag && customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 520)
            .onAppear {
                chosenModel = model.project(task.projectID)?.defaultModel ?? model.state.settings.defaultModel(for: task.agent)
            }
        } else {
            Text("Задача не найдена").padding(40)
        }
    }
}

/// Closing a task that has a worktree: keep it, or remove the worktree and maybe the branch.
struct DoneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: DoneRequest
    @State private var stopSessions = true
    @State private var removeWorktree = false
    @State private var deleteBranch = false

    var body: some View {
        if let task = model.task(request.taskID) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Закрыть \(task.taskID)?").font(.title3.bold())
                Text(task.title).foregroundStyle(.secondary)
                Toggle("Остановить сессии задачи", isOn: $stopSessions)
                    .disabled(model.sessions(for: task).isEmpty)
                if task.worktree != nil {
                    Toggle("Удалить worktree", isOn: $removeWorktree)
                    Toggle("Удалить ветку \(task.branch ?? "")", isOn: $deleteBranch)
                        .disabled(!removeWorktree || task.branch == nil)
                        .padding(.leading, 18)
                        .help("Только если ветка уже слита: несмёрженную ветку git не удалит")
                    Text("Artel не сливает ветку сам. Незакоммиченные изменения в worktree будут потеряны.")
                        .font(.caption).foregroundStyle(.orange)
                        .opacity(removeWorktree ? 1 : 0)
                }
                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Закрыть задачу") {
                        model.closeTask(task, stopSessions: stopSessions, removeWorktree: removeWorktree,
                                        deleteBranch: removeWorktree && deleteBranch)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }
}

struct CommitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CommitRequest
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Коммит .artel/ — \(model.project(request.projectID)?.name ?? "")").font(.title3.bold())
            Text("В коммит попадут только файлы .artel/. Остальные изменения в проекте не затрагиваются.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(request.changes.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            TextField("Сообщение коммита", text: $message, axis: .vertical)
                .lineLimit(1...4)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Закоммитить") { model.performCommit(request, message: message) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { message = request.message }
    }
}
