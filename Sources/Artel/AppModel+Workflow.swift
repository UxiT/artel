import ArtelCore
import AppKit

/// "Done" for a task with a worktree: the operator decides what happens to it.
struct DoneRequest: Identifiable {
    let id = UUID()
    var taskID: String
}

extension AppModel {
    func baseBranch(for project: Project) -> String {
        project.baseBranch ?? git?.currentBranch(project.path) ?? "main"
    }

    /// Status chosen by the operator (menu, board). Closing a task with a worktree asks what to do with it.
    func setStatus(_ task: ArtelTask, _ status: TaskStatus) {
        guard task.status != status else { return }
        if status == .done, task.worktree != nil {
            doneRequest = DoneRequest(taskID: task.id)
            return
        }
        var t = task
        t.status = status
        updateTask(t, debounce: false)
    }

    /// Closes the task; optionally stops its sessions and removes the worktree (and the branch).
    /// Merging the branch is up to the operator (or the agent) — Artel doesn't merge.
    func closeTask(_ task: ArtelTask, stopSessions: Bool, removeWorktree: Bool, deleteBranch: Bool) {
        guard let project = project(task.projectID) else { return }
        var t = self.task(task.id) ?? task
        // The session's cwd disappears with the worktree.
        if stopSessions || removeWorktree {
            for s in sessions(for: t) where stopSessions || s.cwd == t.worktree { stopSession(s.id) }
        }
        if removeWorktree, let git, let wt = t.worktree {
            do {
                try git.removeWorktree(repo: project.path, path: wt)
                record(t, TaskHistoryEntry(actor: .artel, kind: .note, text: "Worktree removed"))
                t.worktree = nil
                if deleteBranch, let branch = t.branch {
                    // Not forced: git refuses to drop a branch that isn't merged anywhere.
                    try git.deleteBranch(repo: project.path, branch: branch, force: false)
                    record(t, TaskHistoryEntry(actor: .artel, kind: .note, text: "Branch \(branch) deleted"))
                    t.branch = nil
                }
            } catch {
                errorMessage = "The task is closed, but git couldn't remove the worktree or branch: \(error.localizedDescription)"
            }
        }
        t.status = .done
        updateTask(t, debounce: false)
    }
}
