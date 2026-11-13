import Foundation

/// Filesystem operations on a project's `.artel/` folder.
public enum TaskStore {
    public static let folderName = ".artel"

    /// `.artel`, or `.aide` in a project that got tasks before the rename and still keeps them there.
    public static func dirName(_ project: Project) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: project.url.appendingPathComponent(folderName).path),
           fm.fileExists(atPath: project.url.appendingPathComponent(LegacyAide.projectDirName).path) {
            return LegacyAide.projectDirName
        }
        return folderName
    }

    public static func artelDir(_ project: Project) -> URL { project.url.appendingPathComponent(dirName(project), isDirectory: true) }
    public static func tasksDir(_ project: Project) -> URL { artelDir(project).appendingPathComponent("tasks", isDirectory: true) }

    /// Loads every task of a project. Folders without a parsable task.md are skipped.
    public static func load(_ project: Project) -> [ArtelTask] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: tasksDir(project), includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return dirs.compactMap { dir in
            guard let text = try? String(contentsOf: dir.appendingPathComponent("task.md"), encoding: .utf8) else { return nil }
            return TaskFile.parse(text, projectID: project.id, directory: dir)
        }
    }

    /// Modification dates of every task.md — cheap change detection for polling.
    public static func fingerprint(_ project: Project) -> [String: Date] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: tasksDir(project).path) else { return [:] }
        var out: [String: Date] = [:]
        for d in dirs {
            let path = tasksDir(project).appendingPathComponent(d).appendingPathComponent("task.md").path
            if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date { out[d] = date }
        }
        return out
    }

    /// Next id: numbering is shared by all prefixes inside a project (`ARTEL-7` → `OPS-8`).
    public static func nextTaskID(_ project: Project, existing: [ArtelTask]) -> String {
        var maxN = 0
        let names = existing.map(\.taskID) + ((try? FileManager.default.contentsOfDirectory(atPath: tasksDir(project).path)) ?? [])
        for name in names {
            // "<PREFIX>-<n>" or "<PREFIX>-<n>-slug"
            let parts = name.split(separator: "-")
            if parts.count >= 2, let n = Int(parts[1]) { maxN = max(maxN, n) }
        }
        return "\(project.taskPrefix)-\(maxN + 1)"
    }

    public static func slug(_ title: String, maxLength: Int = 40) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        var out = ""
        var lastDash = false
        for ch in latin.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "task" : out
    }

    /// Creates the task folder and task.md. Also ensures `.artel/.gitignore` (logs are never committed).
    public static func create(project: Project, title: String, existing: [ArtelTask], body: String = ArtelTask.bodyTemplate(),
                              model: String? = nil, agent: String = ClaudeCodeAgent.id,
                              now: Date = Date()) throws -> ArtelTask {
        let fm = FileManager.default
        try ensureArtelDir(project)
        let id = nextTaskID(project, existing: existing)
        let dir = tasksDir(project).appendingPathComponent("\(id)-\(slug(title))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let task = ArtelTask(projectID: project.id, directory: dir, taskID: id, title: title,
                            agent: agent, model: model, created: now, updated: now, body: body)
        try save(task, project: project)
        return task
    }

    public static func save(_ task: ArtelTask, project: Project) throws {
        try TaskFile.serialize(task, projectName: project.name).write(to: task.file, atomically: true, encoding: .utf8)
    }

    public static func ensureArtelDir(_ project: Project) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tasksDir(project), withIntermediateDirectories: true)
        let ignore = artelDir(project).appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: ignore, encoding: .utf8))
            ?? "# Transcripts and temporary session archives are personal; never commit them.\n"
        let original = text
        for pattern in ["tasks/*/logs/", "no-task/"] where !text.split(whereSeparator: \.isNewline).contains(where: { $0 == pattern }) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += pattern + "\n"
        }
        if text != original { try text.write(to: ignore, atomically: true, encoding: .utf8) }
    }

    /// Snapshots the hook events and, at turn boundaries, the agent's native transcript.
    public static func captureLogs(sessionID: String, in directory: URL, eventsFile: URL? = nil,
                                   transcript: URL? = nil) throws {
        let fm = FileManager.default
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        if let eventsFile {
            try copyIfPresent(eventsFile, to: logs.appendingPathComponent("\(sessionID)-events.jsonl"))
        }
        if let transcript {
            let name = transcript.deletingPathExtension().lastPathComponent
            try copyIfPresent(transcript, to: logs.appendingPathComponent("\(sessionID)-\(name).log"))
        }
    }

    private static func copyIfPresent(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if fm.contentsEqual(atPath: source.path, andPath: target.path) { return }
        try Data(contentsOf: source).write(to: target, options: .atomic)
    }

    /// Copies a file into the task's attachments and returns the markdown to insert.
    public static func attach(_ source: URL, to task: ArtelTask) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: task.attachmentsDir, withIntermediateDirectories: true)
        var target = task.attachmentsDir.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            target = task.attachmentsDir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: source, to: target)
        let rel = "attachments/\(target.lastPathComponent)"
        let isImage = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(target.pathExtension.lowercased())
        // Absolute path too: the agent works in a worktree, not next to task.md.
        return isImage ? "![\(target.lastPathComponent)](\(rel)) @\(target.path)" : "[\(target.lastPathComponent)](\(rel)) @\(target.path)"
    }

    /// Reference text for a dropped file: project files become `@relative/path`, others get attached.
    public static func reference(for url: URL, project: Project, task: ArtelTask) throws -> String {
        let root = project.url.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root), !path.hasPrefix(artelDir(project).path) {
            return "@" + String(path.dropFirst(root.count))
        }
        return try attach(url, to: task)
    }
}
