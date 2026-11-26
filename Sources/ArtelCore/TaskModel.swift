import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case new
    case inProgress = "in-progress"
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .new: "New"
        case .inProgress: "In Progress"
        case .done: "Done"
        }
    }

    public var isClosed: Bool { self == .done }

    /// Sort order in the task list: active work first, closed last.
    public var sortRank: Int {
        switch self {
        case .inProgress: 0
        case .new: 1
        case .done: 2
        }
    }

    /// Reads current and legacy values: the old workflow stages (plan, review, testing…) count as
    /// work in progress, a cancelled task as closed.
    public init?(stored raw: String) {
        switch raw {
        case "new": self = .new
        case "done", "cancelled": self = .done
        case "plan", "plan-review", "in-progress", "review", "testing": self = .inProgress
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let status = TaskStatus(stored: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown status \(raw)"))
        }
        self = status
    }
}

/// A task: `.artel/tasks/<ID>-<slug>/task.md` (YAML-ish frontmatter + markdown body).
public struct ArtelTask: Equatable, Identifiable, Sendable {
    /// Globally unique: tasks of different projects may share an id like `ARTEL-1`.
    public var id: String { "\(projectID.uuidString)/\(taskID)" }

    public var projectID: UUID
    /// Folder holding task.md, attachments and logs.
    public var directory: URL

    public var taskID: String
    public var title: String
    public var status: TaskStatus
    public var agent: String
    public var model: String?
    /// Set once the task got its own git worktree; nil = it runs in the project checkout.
    public var branch: String?
    public var worktree: String?
    public var sessions: [String]
    public var created: Date
    public var updated: Date
    /// Markdown after the frontmatter — the prompt.
    public var body: String
    /// Frontmatter keys Artel doesn't know, kept verbatim.
    public var extraFrontmatter: [String]

    public init(projectID: UUID, directory: URL, taskID: String, title: String, status: TaskStatus = .new,
                agent: String = ClaudeCodeAgent.id, model: String? = nil,
                branch: String? = nil, worktree: String? = nil, sessions: [String] = [],
                created: Date = Date(), updated: Date = Date(), body: String = "", extraFrontmatter: [String] = []) {
        self.projectID = projectID
        self.directory = directory
        self.taskID = taskID
        self.title = title
        self.status = status
        self.agent = agent
        self.model = model
        self.branch = branch
        self.worktree = worktree
        self.sessions = sessions
        self.created = created
        self.updated = updated
        self.body = body
        self.extraFrontmatter = extraFrontmatter
    }

    public var file: URL { directory.appendingPathComponent("task.md") }
    public var attachmentsDir: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    public static func bodyTemplate() -> String {
        """
        ## What to do


        ## Context


        ## References


        ## Acceptance criteria
        - [ ]

        ## Constraints

        """
    }
}

// MARK: - task.md format

public enum TaskFile {
    // ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ text: String, projectID: UUID, directory: URL) -> ArtelTask? {
        guard let (front, body) = splitFrontmatter(text) else { return nil }
        var fields: [String: String] = [:]
        var order: [String] = []
        var extra: [String] = []
        for line in front {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { extra.append(line) }
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if knownKeys.contains(key) {
                fields[key] = stripComment(value)
                order.append(key)
            } else if obsoleteKeys.contains(key) {
                continue
            } else {
                extra.append(line)
            }
        }
        guard let id = fields["id"].map(unquote), !id.isEmpty else { return nil }
        let now = Date()
        return ArtelTask(
            projectID: projectID, directory: directory, taskID: id,
            title: fields["title"].map(unquote) ?? id,
            status: fields["status"].flatMap { TaskStatus(stored: unquote($0)) } ?? .new,
            agent: fields["agent"].map(unquote).flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeCodeAgent.id,
            model: fields["model"].map(unquote).flatMap { $0.isEmpty ? nil : $0 },
            branch: fields["branch"].map(unquote).flatMap { $0.isEmpty ? nil : $0 },
            worktree: fields["worktree"].map(unquote).flatMap { $0.isEmpty ? nil : $0 },
            sessions: fields["sessions"].map(parseList) ?? [],
            created: fields["created"].flatMap { dateFormatter.date(from: unquote($0)) } ?? now,
            updated: fields["updated"].flatMap { dateFormatter.date(from: unquote($0)) } ?? now,
            body: body,
            extraFrontmatter: extra
        )
    }

    public static func serialize(_ t: ArtelTask, projectName: String) -> String {
        var lines = ["---"]
        lines.append("id: \(t.taskID)")
        lines.append("title: \(quote(t.title))")
        lines.append("project: \(quote(projectName))")
        lines.append("status: \(t.status.rawValue)")
        lines.append("agent: \(t.agent)")
        lines.append("model: \(t.model.map(quote) ?? "")")
        lines.append("branch: \(t.branch ?? "")")
        lines.append("worktree: \(t.worktree.map(quote) ?? "")")
        lines.append("sessions: \(list(t.sessions))")
        lines.append("created: \(dateFormatter.string(from: t.created))")
        lines.append("updated: \(dateFormatter.string(from: t.updated))")
        lines.append(contentsOf: t.extraFrontmatter)
        lines.append("---")
        var body = t.body
        if !body.hasPrefix("\n") { body = "\n" + body }
        if !body.hasSuffix("\n") { body += "\n" }
        return lines.joined(separator: "\n") + "\n" + body
    }

    static let knownKeys: Set<String> = ["id", "title", "project", "status", "agent", "model", "branch", "worktree",
                                         "sessions", "created", "updated"]
    /// Keys of the removed plan/review/testing workflow: dropped when the task is rewritten.
    static let obsoleteKeys: Set<String> = ["priority", "depends_on", "review", "testing", "iteration",
                                            "awaiting_agent", "merge_conflict"]

    static func splitFrontmatter(_ text: String) -> ([String], String)? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil)
        else { return nil }
        let front = rest[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = String(rest[end.upperBound...])
        return (front, body)
    }

    static func stripComment(_ value: String) -> String {
        // `key: value  # comment` — only when the value isn't quoted.
        guard !value.hasPrefix("\""), !value.hasPrefix("'"), let hash = value.range(of: " #") else { return value }
        return value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let first = t.first, let last = t.last, first == last, first == "\"" || first == "'" else { return t }
        let inner = String(t.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") : inner
    }

    static func quote(_ s: String) -> String {
        let needs = s.isEmpty || s.contains(where: { ":#[]{},&*!|>'\"%@`".contains($0) }) || s.hasPrefix(" ") || s.hasSuffix(" ")
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parseList(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") && t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        return t.split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
    }

    static func list(_ items: [String]) -> String { "[" + items.map(quote).joined(separator: ", ") + "]" }
}

extension ArtelTask {
    /// Three-way merge of a task edited in memory (`local`) with the file on disk (`disk`), both
    /// derived from `base`. Fields the operator changed in Artel win; everything else takes the disk
    /// value, so edits made to task.md outside Artel aren't overwritten by a pending editor save.
    public static func merged(local: ArtelTask, base: ArtelTask, disk: ArtelTask) -> ArtelTask {
        var out = disk
        func pick<T: Equatable>(_ kp: WritableKeyPath<ArtelTask, T>) {
            if local[keyPath: kp] != base[keyPath: kp] { out[keyPath: kp] = local[keyPath: kp] }
        }
        pick(\.title); pick(\.status); pick(\.agent); pick(\.model); pick(\.branch); pick(\.worktree)
        pick(\.sessions); pick(\.body); pick(\.extraFrontmatter)
        out.updated = max(local.updated, disk.updated)
        return out
    }
}
