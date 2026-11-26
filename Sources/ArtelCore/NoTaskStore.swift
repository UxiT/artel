import Foundation

/// Temporary task-like archives for sessions started without a task.
public enum NoTaskStore {
    public static let directoryName = "no-task"
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    public static func root(_ project: Project) -> URL {
        TaskStore.artelDir(project).appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func directory(_ project: Project, sessionID: String) -> URL {
        root(project).appendingPathComponent(sessionID, isDirectory: true)
    }

    public static func archiveID(sessionID: String) -> String { "NO-\(sessionID)" }

    /// One line of the first prompt, short enough for session and task headers.
    public static func title(from prompt: String, maxLength: Int = 80) -> String? {
        guard let line = prompt.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let title = line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard title.count > maxLength else { return title }
        return String(title.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Loads archives and removes expired ones. Live sessions can be protected from cleanup.
    public static func load(_ project: Project, now: Date = Date(), preserving sessionIDs: Set<String> = []) -> [ArtelTask] {
        cleanup(project, now: now, preserving: sessionIDs)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root(project), includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return dirs.compactMap { dir in
            guard let text = try? String(contentsOf: dir.appendingPathComponent("task.md"), encoding: .utf8) else { return nil }
            return TaskFile.parse(text, projectID: project.id, directory: dir)
        }.sorted { $0.updated > $1.updated }
    }

    /// Hook events captured for all conversations in an archive, in chronological order.
    public static func events(for archive: ArtelTask) -> [HookEvent] {
        let decoder = JSONDecoder.artel
        return archive.sessions.flatMap { sessionID -> [HookEvent] in
            let url = archive.directory.appendingPathComponent("logs/\(sessionID)-events.jsonl")
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(HookEvent.self, from: Data($0)) }
        }.sorted { $0.timestamp < $1.timestamp }
    }

    /// All readable artifacts of an archive, including the event logs and native transcripts.
    public static func files(for archive: ArtelTask) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: archive.directory, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
        let prefix = archive.directory.path + "/"
        return files.sorted {
            $0.path.replacingOccurrences(of: prefix, with: "") < $1.path.replacingOccurrences(of: prefix, with: "")
        }
    }

    /// Cheap change detection; reading the archive root also runs retention cleanup.
    public static func fingerprint(_ project: Project, now: Date = Date(), preserving sessionIDs: Set<String> = []) -> [String: Date] {
        cleanup(project, now: now, preserving: sessionIDs)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root(project).path) else { return [:] }
        var out: [String: Date] = [:]
        for dir in dirs {
            let path = root(project).appendingPathComponent(dir).appendingPathComponent("task.md").path
            if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date { out[dir] = date }
        }
        return out
    }

    /// Creates or updates an archive and snapshots the logs that are currently available.
    @discardableResult
    public static func archive(session: SessionRecord, project: Project, firstPrompt: String? = nil,
                               eventsFile: URL? = nil, transcript: URL? = nil, now: Date = Date(),
                               preserving sessionIDs: Set<String> = []) throws -> ArtelTask {
        try TaskStore.ensureArtelDir(project)
        cleanup(project, now: now, preserving: sessionIDs.union([session.id]))
        let fm = FileManager.default
        let dir = directory(project, sessionID: session.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = dir.appendingPathComponent("task.md")
        let existing = (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { TaskFile.parse($0, projectID: project.id, directory: dir) }
        let prompt = firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPrompt = existing.map { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let title = existing?.title ?? session.name
        var task = existing ?? ArtelTask(
            projectID: project.id, directory: dir, taskID: archiveID(sessionID: session.id),
            title: title, status: .done, agent: session.agentID, model: session.model,
            sessions: [session.id], created: session.createdAt, updated: now
        )
        if let prompt, !prompt.isEmpty, !hasPrompt {
            task.title = Self.title(from: prompt) ?? task.title
            task.body = "\n" + prompt + "\n"
        }
        task.updated = now
        task.agent = session.agentID
        task.model = session.model
        if !task.sessions.contains(session.id) { task.sessions.append(session.id) }
        try TaskStore.save(task, project: project)
        if existing == nil {
            try TaskHistory.append(TaskHistoryEntry(date: session.createdAt, actor: .artel, kind: .created,
                                                    text: "Session without a task archived"), in: dir)
        }

        try TaskStore.captureLogs(sessionID: session.id, in: dir, eventsFile: eventsFile, transcript: transcript)
        return task
    }

    /// Turns an archive into a numbered, closed task and keeps its history and logs.
    public static func promote(_ archive: ArtelTask, project: Project, existing: [ArtelTask],
                               now: Date = Date()) throws -> ArtelTask {
        try TaskStore.ensureArtelDir(project)
        let id = TaskStore.nextTaskID(project, existing: existing)
        let target = TaskStore.tasksDir(project).appendingPathComponent("\(id)-\(TaskStore.slug(archive.title))", isDirectory: true)
        try FileManager.default.moveItem(at: archive.directory, to: target)
        var task = archive
        task.directory = target
        task.taskID = id
        task.status = .done
        task.branch = nil
        task.worktree = nil
        task.updated = now
        do {
            try TaskStore.save(task, project: project)
            try TaskHistory.append(TaskHistoryEntry(date: now, actor: .operator, kind: .note,
                                                    text: "Added to the board from the no-task archive"), in: target)
        } catch {
            try? FileManager.default.moveItem(at: target, to: archive.directory)
            throw error
        }
        return task
    }

    /// Deletes expired archives. The timestamp in task.md is the last session activity.
    public static func cleanup(_ project: Project, now: Date = Date(), preserving sessionIDs: Set<String> = []) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root(project), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            return
        }
        for dir in dirs {
            let file = dir.appendingPathComponent("task.md")
            let task = (try? String(contentsOf: file, encoding: .utf8))
                .flatMap { TaskFile.parse($0, projectID: project.id, directory: dir) }
            if let task, !Set(task.sessions).isDisjoint(with: sessionIDs) { continue }
            if task == nil, sessionIDs.contains(dir.lastPathComponent) { continue }
            let modified = task?.updated
                ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            if now.timeIntervalSince(modified) > retentionInterval {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
