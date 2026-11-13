import Foundation

/// The first message a task session gets: the prompt frame filled with the task.
public enum TaskPrompt {
    public static func build(task: ArtelTask, project: Project, worktree: String?,
                             frame: String = PromptTemplate.defaultFrame) -> String {
        let values: [String: String] = [
            "task_id": task.taskID,
            "title": task.title,
            "project": project.name,
            "worktree": worktree ?? "",
            "branch": worktree == nil ? "" : (task.branch ?? ""),
            "task_dir": task.directory.path,
            "task_body": task.body.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return PromptTemplate.render(frame, values)
    }
}
