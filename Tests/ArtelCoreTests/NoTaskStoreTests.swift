import Foundation
import Testing
@testable import ArtelCore

@Suite struct NoTaskStoreTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artel-no-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func session(id: String = "abc123", created: Date = Date(timeIntervalSince1970: 1_000)) -> SessionRecord {
        SessionRecord(id: id, name: "Проект #1", projectID: UUID(), cwd: "/tmp", model: "sonnet",
                      permissionMode: "auto", createdAt: created)
    }

    @Test func titleUsesFirstPromptLine() {
        #expect(NoTaskStore.title(from: "\n  Починить   вход\nи добавить тест") == "Починить вход")
        #expect(NoTaskStore.title(from: " \n") == nil)
        #expect(NoTaskStore.title(from: String(repeating: "а", count: 100))?.count == 80)
    }

    @Test func archiveKeepsFirstPromptAndSnapshotsLogs() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(id: UUID(), name: "p", path: root.path)
        var record = session()
        record.projectID = project.id
        let events = root.appendingPathComponent("events.jsonl")
        let transcript = root.appendingPathComponent("conversation.jsonl")
        try "one\n".write(to: events, atomically: true, encoding: .utf8)
        try "transcript\n".write(to: transcript, atomically: true, encoding: .utf8)

        let saved = try NoTaskStore.archive(session: record, project: project,
                                            firstPrompt: "\nПочинить   вход\nи добавить тест",
                                            eventsFile: events, transcript: transcript,
                                            now: Date(timeIntervalSince1970: 2_000))
        #expect(saved.taskID == "NO-abc123")
        #expect(saved.status == .done)
        #expect(saved.title == "Починить вход")
        #expect(saved.body == "\nПочинить   вход\nи добавить тест\n")
        #expect(saved.created == record.createdAt)
        let logs = saved.directory.appendingPathComponent("logs")
        #expect(try String(contentsOf: logs.appendingPathComponent("abc123-events.jsonl"), encoding: .utf8) == "one\n")
        #expect(try String(contentsOf: logs.appendingPathComponent("abc123-conversation.log"), encoding: .utf8) == "transcript\n")
        let ignore = try String(contentsOf: root.appendingPathComponent(".artel/.gitignore"), encoding: .utf8)
        #expect(ignore.contains("no-task/"))

        let updated = try NoTaskStore.archive(session: record, project: project, firstPrompt: "Другой промпт",
                                              now: Date(timeIntervalSince1970: 3_000))
        #expect(updated.title == saved.title)
        #expect(updated.body == saved.body)
        #expect(NoTaskStore.load(project, now: Date(timeIntervalSince1970: 3_000)).count == 1)
    }

    @Test func readsCapturedEventsAndListsArchiveFiles() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(id: UUID(), name: "p", path: root.path)
        var record = session()
        record.projectID = project.id
        let archive = try NoTaskStore.archive(session: record, project: project, firstPrompt: "Проверить архив")
        let event = HookEvent(artelSessionID: record.id, timestamp: Date(timeIntervalSince1970: 2_000),
                              name: "Stop", lastAssistantMessage: "Всё готово")
        var data = try JSONEncoder.artel.encode(event)
        data.append(0x0A)
        let log = archive.directory.appendingPathComponent("logs/abc123-events.jsonl")
        try data.write(to: log)

        #expect(NoTaskStore.events(for: archive).map(\.lastAssistantMessage) == ["Всё готово"])
        let files = NoTaskStore.files(for: archive).map { $0.lastPathComponent }
        #expect(files.contains("task.md"))
        #expect(files.contains("history.jsonl"))
        #expect(files.contains("abc123-events.jsonl"))
    }

    @Test func cleanupRunsOnReadAndPreservesLiveSessions() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "p", path: root.path)
        let now = Date(timeIntervalSince1970: 10_000_000)
        var old = session(id: "old")
        var recent = session(id: "recent")
        old.projectID = project.id
        recent.projectID = project.id
        let oldArchive = try NoTaskStore.archive(session: old, project: project,
                                                 now: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let recentArchive = try NoTaskStore.archive(session: recent, project: project, now: now, preserving: ["old"])

        let preserved = NoTaskStore.load(project, now: now, preserving: ["old"])
        #expect(Set(preserved.map(\.taskID)) == ["NO-old", "NO-recent"])
        let remaining = NoTaskStore.load(project, now: now)
        #expect(remaining.map(\.taskID) == ["NO-recent"])
        #expect(!FileManager.default.fileExists(atPath: oldArchive.directory.path))
        #expect(FileManager.default.fileExists(atPath: recentArchive.directory.path))
    }

    @Test func promoteMovesHistoryAndLogsToNumberedDoneTask() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "p", path: root.path)
        let existing = try TaskStore.create(project: project, title: "Обычная", existing: [])
        var record = session()
        record.projectID = project.id
        let transcript = root.appendingPathComponent("conversation.jsonl")
        try "full transcript".write(to: transcript, atomically: true, encoding: .utf8)
        let archive = try NoTaskStore.archive(session: record, project: project, firstPrompt: "Разобраться с логами",
                                              transcript: transcript, now: Date(timeIntervalSince1970: 2_000))

        let promoted = try NoTaskStore.promote(archive, project: project, existing: [existing],
                                               now: Date(timeIntervalSince1970: 3_000))
        #expect(promoted.taskID == "ARTEL-2")
        #expect(promoted.status == .done)
        #expect(promoted.title == "Разобраться с логами")
        #expect(promoted.created == archive.created)
        #expect(promoted.updated == Date(timeIntervalSince1970: 3_000))
        #expect(promoted.sessions == [record.id])
        #expect(!FileManager.default.fileExists(atPath: archive.directory.path))
        let promotedLog = promoted.directory.appendingPathComponent("logs/abc123-conversation.log")
        #expect(FileManager.default.fileExists(atPath: promotedLog.path))
        try "continued".write(to: transcript, atomically: true, encoding: .utf8)
        try TaskStore.captureLogs(sessionID: record.id, in: promoted.directory, transcript: transcript)
        #expect(try String(contentsOf: promotedLog, encoding: .utf8) == "continued")
        #expect(TaskHistory.load(from: promoted.directory).contains {
            $0.kind == .note && $0.text.contains("no-task archive")
        })
        #expect(Set(TaskStore.load(project).map(\.taskID)) == ["ARTEL-1", "ARTEL-2"])
        #expect(NoTaskStore.load(project).isEmpty)
    }
}
