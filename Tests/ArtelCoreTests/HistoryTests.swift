import Foundation
import Testing
@testable import ArtelCore

@Suite struct HistoryTests {
    func tempTask() throws -> ArtelTask {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var t = ArtelTask(projectID: UUID(), directory: dir, taskID: "ARTEL-1", title: "T")
        t.created = Date(timeIntervalSince1970: 1_000)
        return t
    }

    @Test func appendAndLoadRoundTrip() throws {
        let t = try tempTask()
        defer { try? FileManager.default.removeItem(at: t.directory) }
        try TaskHistory.append(TaskHistoryEntry(date: Date(timeIntervalSince1970: 2_000), actor: .operator, kind: .status,
                                                from: .new, to: .inProgress), in: t.directory)
        try TaskHistory.append(TaskHistoryEntry(date: Date(timeIntervalSince1970: 3_000), actor: .artel, kind: .launch,
                                                text: "Агент запущен"), in: t.directory)
        let loaded = TaskHistory.load(from: t.directory)
        #expect(loaded.count == 2)
        #expect(loaded[0].to == .inProgress && loaded[1].kind == .launch)
        // Timeline adds the creation from task.md, first.
        let timeline = TaskHistory.timeline(for: t)
        #expect(timeline.map(\.kind) == [.created, .status, .launch])
    }

    @Test func oldWorkflowEntriesStillLoad() throws {
        let t = try tempTask()
        defer { try? FileManager.default.removeItem(at: t.directory) }
        let lines = [
            #"{"actor":"agent","date":"2026-11-01T10:00:00Z","from":"plan","kind":"status","text":"","to":"plan-review"}"#,
            #"{"actor":"agent","date":"2026-11-01T10:01:00Z","file":"plan.md","iteration":1,"kind":"artifact","text":"написал plan.md"}"#,
            #"{"actor":"operator","date":"2026-11-01T10:02:00Z","kind":"status","from":"testing","to":"cancelled","text":""}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: TaskHistory.file(in: t.directory), atomically: true, encoding: .utf8)
        let loaded = TaskHistory.load(from: t.directory)
        #expect(loaded.map(\.kind) == [.status, .artifact, .status])
        #expect(loaded[0].from == .inProgress && loaded[0].to == .inProgress)
        #expect(loaded[2].to == .done)
        // "plan → plan-review" reads as "in progress → in progress": hidden from the timeline.
        #expect(TaskHistory.timeline(for: t).map(\.kind) == [.created, .artifact, .status])
    }
}
