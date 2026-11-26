import ArtelCore
import AppKit

extension AppModel {
    var liveNoTaskSessionIDs: Set<String> {
        Set(state.sessions.filter { $0.taskID == nil }.map(\.id))
    }

    func noTask(sessionID: String) -> ArtelTask? {
        noTasks.first { $0.sessions.contains(sessionID) }
    }

    func noTask(_ id: String) -> ArtelTask? {
        noTasks.first { $0.id == id }
    }

    func openNoTask(_ id: String) {
        openedTaskID = nil
        selectedTaskID = nil
        openedNoTaskID = id
        taskWindowRequest += 1
    }

    func reloadNoTasks(of project: Project) {
        noTasks.removeAll { $0.projectID == project.id }
        noTasks.append(contentsOf: NoTaskStore.load(project, preserving: liveNoTaskSessionIDs))
        noTaskFingerprints[project.id] = NoTaskStore.fingerprint(project, preserving: liveNoTaskSessionIDs)
    }

    /// Saves the current event log on every hook; the larger native transcript is captured at turn boundaries.
    func archiveSession(_ record: SessionRecord, prompt: String? = nil, captureTranscript: Bool = false) {
        if record.taskID != nil {
            guard let task = task(for: record) else { return }
            do {
                try TaskStore.captureLogs(
                    sessionID: record.id, in: task.directory,
                    eventsFile: AppPaths.eventsFile(sessionID: record.id),
                    transcript: captureTranscript ? status(record.id).transcriptPath.map(URL.init(fileURLWithPath:)) : nil
                )
            } catch {
                errorMessage = "Couldn't save the session log: \(error.localizedDescription)"
            }
            return
        }
        guard let project = project(record.projectID) else { return }
        guard record.archivesNoTask else {
            titleFromFirstPrompt(record, prompt: prompt)
            return
        }
        let existing = noTask(sessionID: record.id)
        let needsPrompt = existing.map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        let firstPrompt = needsPrompt ? (prompt ?? EventLog.read(sessionID: record.id).first {
            $0.name == "UserPromptSubmit" && !($0.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }?.prompt) : nil
        do {
            let archived = try NoTaskStore.archive(
                session: record, project: project, firstPrompt: firstPrompt,
                eventsFile: AppPaths.eventsFile(sessionID: record.id),
                transcript: captureTranscript ? status(record.id).transcriptPath.map(URL.init(fileURLWithPath:)) : nil,
                preserving: liveNoTaskSessionIDs
            )
            if let i = noTasks.firstIndex(where: { $0.id == archived.id }) {
                noTasks[i] = archived
            } else {
                noTasks.append(archived)
            }
            noTaskFingerprints[project.id] = NoTaskStore.fingerprint(project, preserving: liveNoTaskSessionIDs)
            if let firstPrompt, let title = NoTaskStore.title(from: firstPrompt), var current = self.record(record.id) {
                current.name = title
                replace(current)
            }
        } catch {
            errorMessage = "Couldn't save the session archive: \(error.localizedDescription)"
        }
    }

    /// Without an archive the first prompt still names the session; later prompts don't rename it.
    private func titleFromFirstPrompt(_ record: SessionRecord, prompt: String?) {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return }
        let first = EventLog.read(sessionID: record.id).first {
            $0.name == "UserPromptSubmit" && !($0.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard first == nil || first == prompt, let title = NoTaskStore.title(from: prompt),
              var current = self.record(record.id), current.name != title else { return }
        current.name = title
        replace(current)
    }

    /// Turns the no-task archive of a live session on or off. Turning it on snapshots what is there right away;
    /// turning it off keeps the archive written so far (it expires as usual).
    func setArchivesNoTask(_ enabled: Bool, sessionID: String) {
        guard var record = record(sessionID), record.archivesNoTask != enabled else { return }
        record.archivesNoTask = enabled
        replace(record)
        if enabled { archiveSession(record, captureTranscript: true) }
    }

    /// Adds an archived session to the board as a closed task, preserving all files.
    func convertNoTask(_ archive: ArtelTask) {
        guard let project = project(archive.projectID) else { return }
        do {
            let task = try NoTaskStore.promote(archive, project: project,
                                               existing: tasks.filter { $0.projectID == project.id })
            noTasks.removeAll { $0.id == archive.id }
            tasks.append(task)
            taskBaselines[task.id] = task
            taskFingerprints[project.id] = TaskStore.fingerprint(project)
            noTaskFingerprints[project.id] = NoTaskStore.fingerprint(project, preserving: liveNoTaskSessionIDs)
            for sessionID in task.sessions {
                guard var record = record(sessionID), record.taskID == nil else { continue }
                record.taskID = task.taskID
                replace(record)
            }
            historyVersion += 1
            refreshArtelDirty()
            openTask(task.id)
        } catch {
            errorMessage = "Couldn't create a task from the archive: \(error.localizedDescription)"
        }
    }

    func convertNoTask(sessionID: String) {
        if let archive = noTask(sessionID: sessionID) { convertNoTask(archive) }
    }

    func visibleNoTasks(of project: Project) -> [ArtelTask] {
        let taskFilter = sidebarFilter
        guard taskFilter.projects.isEmpty || taskFilter.projects.contains(project.id) else { return [] }
        let query = taskFilter.search.trimmingCharacters(in: .whitespaces)
        return noTasks.filter { archive in
            guard archive.projectID == project.id else { return false }
            // A live session already has its own row and a conversion action in its menu.
            guard !state.sessions.contains(where: { $0.taskID == nil && archive.sessions.contains($0.id) }) else { return false }
            return query.isEmpty || archive.title.localizedCaseInsensitiveContains(query)
                || archive.body.localizedCaseInsensitiveContains(query)
        }
    }

    func revealNoTaskLog(_ archive: ArtelTask) {
        let logs = archive.directory.appendingPathComponent("logs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        if let log = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(archive.directory)
        }
    }
}
