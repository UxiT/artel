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
            // The last worktree choice is remembered across projects; a folder without git can't use it.
            let isGit = model.project(task.projectID)?.isGitRepository ?? false
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch \(task.taskID)").font(.title3.bold())
                    Text(task.title).foregroundStyle(.secondary)
                    Text(target.map { "Into session “\($0.name)”" } ?? "Into a new session")
                        .font(.callout)
                }

                Form {
                    if needsModel {
                        Picker("Model", selection: $chosenModel) {
                            ForEach(agent.models) { m in Text(m.title).tag(m.id) }
                            Text("Other…").tag(Optional(customTag))
                        }
                        if chosenModel == customTag {
                            TextField("Model ID", text: $customModel)
                        }
                        Toggle("Save Model in Task", isOn: $saveModel)
                    } else {
                        LabeledContent("Model", value: task.model ?? "")
                    }

                    if let worktree = task.worktree {
                        LabeledContent("Worktree") {
                            Text(worktree).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                        }
                    } else if isGit {
                        Toggle("Separate Git Worktree", isOn: $useWorktree)
                        Text(useWorktree
                             ? "The agent works in a copy of the project on branch \(WorktreeLayout.branch(for: task)). You merge it yourself."
                             : "The agent works directly in the project's working copy.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Working Folder", value: "Project folder")
                        Text("The project isn't a git repository, so a separate worktree isn't available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let target {
                        Toggle("Clear Previous Session Context", isOn: otherTask ? .constant(true) : $clearContext)
                            .disabled(otherTask)
                        if otherTask {
                            Label(
                                "The session is currently attached to \(target.taskID.map { "task \($0)" } ?? "work without a task") (\(model.project(target.projectID)?.name ?? "")). Its context will be cleared and the agent will restart in the working directory of task \(task.taskID).",
                                systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Launch") {
                        let m: String? = needsModel ? (chosenModel == customTag ? customModel.trimmingCharacters(in: .whitespaces) : chosenModel) : task.model
                        model.launch(request, model: m, saveModel: needsModel && saveModel,
                                     clearContext: otherTask || clearContext, useWorktree: isGit && useWorktree)
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
            Text("Task not found").padding(40)
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
                Text("Close \(task.taskID)?").font(.title3.bold())
                Text(task.title).foregroundStyle(.secondary)
                Toggle("Stop Task Sessions", isOn: $stopSessions)
                    .disabled(model.sessions(for: task).isEmpty)
                if task.worktree != nil {
                    Toggle("Delete Worktree", isOn: $removeWorktree)
                    Toggle("Delete Branch \(task.branch ?? "")", isOn: $deleteBranch)
                        .disabled(!removeWorktree || task.branch == nil)
                        .padding(.leading, 18)
                        .help("Only if the branch is already merged: git won't delete an unmerged branch")
                    Text("Artel doesn't merge the branch for you. Uncommitted changes in the worktree will be lost.")
                        .font(.caption).foregroundStyle(.orange)
                        .opacity(removeWorktree ? 1 : 0)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Close Task") {
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
            Text("Commit .artel/ — \(model.project(request.projectID)?.name ?? "")").font(.title3.bold())
            Text("Only files in .artel/ go into the commit. Other changes in the project are left alone.")
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
            TextField("Commit Message", text: $message, axis: .vertical)
                .lineLimit(1...4)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Commit") { model.performCommit(request, message: message) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { message = request.message }
    }
}
