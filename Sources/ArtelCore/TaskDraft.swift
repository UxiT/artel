import Foundation

/// A task being written in the task window before it exists on disk: the project is chosen there too.
public struct TaskDraft: Equatable, Sendable {
    public var projectID: UUID
    public var title: String
    public var body: String
    public var model: String?
    /// Agent id (CodingAgent.id) that will work on the task.
    public var agent: String

    /// A draft for `project` with its default model.
    public init(project: Project, title: String = "", body: String = ArtelTask.bodyTemplate(),
                agent: String = ClaudeCodeAgent.id) {
        projectID = project.id
        self.title = title
        self.body = body
        model = project.defaultModel
        self.agent = agent
    }

    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canCreate: Bool { !trimmedTitle.isEmpty }

    /// Moves the draft to another project. Settings still at the old project's defaults follow
    /// the new project's defaults; ones the operator changed are kept.
    public mutating func switchProject(to new: Project, from old: Project?) {
        guard new.id != projectID else { return }
        projectID = new.id
        if model == old?.defaultModel { model = new.defaultModel }
    }
}

extension TaskStore {
    /// Creates the task described by a draft in `project` (the draft's project).
    public static func create(_ draft: TaskDraft, project: Project, existing: [ArtelTask],
                              now: Date = Date()) throws -> ArtelTask {
        try create(project: project, title: draft.trimmedTitle, existing: existing, body: draft.body,
                   model: draft.model, agent: draft.agent, now: now)
    }
}
