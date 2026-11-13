import Foundation
import Testing
@testable import ArtelCore

@Suite struct TaskDraftTests {
    let a = Project(name: "a", path: "/tmp/a", defaultModel: "opus")
    let b = Project(name: "b", path: "/tmp/b", defaultModel: "sonnet", taskPrefix: "B")

    @Test func startsWithProjectDefaults() {
        let d = TaskDraft(project: a, title: "  ", body: "тело")
        #expect(d.projectID == a.id)
        #expect(d.model == "opus" && d.body == "тело")
        #expect(!d.canCreate)
    }

    @Test func titleIsRequiredAndTrimmed() {
        var d = TaskDraft(project: a)
        d.title = "  Форма логина \n"
        #expect(d.canCreate)
        #expect(d.trimmedTitle == "Форма логина")
    }

    @Test func switchingProjectFollowsDefaultsUnlessChanged() {
        var d = TaskDraft(project: a)
        d.switchProject(to: b, from: a)
        #expect(d.projectID == b.id)
        #expect(d.model == "sonnet")

        var e = TaskDraft(project: a)
        e.model = "haiku"
        e.switchProject(to: b, from: a)
        #expect(e.projectID == b.id)
        #expect(e.model == "haiku")  // changed by the operator: kept
    }

    @Test func switchingToSameProjectChangesNothing() {
        var d = TaskDraft(project: a)
        d.model = "haiku"
        d.switchProject(to: a, from: a)
        #expect(d.model == "haiku")
    }

    @Test func createsTaskInChosenProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artel-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "p", path: root.path, taskPrefix: "OPS")
        var d = TaskDraft(project: a, title: " Починить деплой ", body: "## Что сделать\nДеплой.\n")
        d.switchProject(to: project, from: a)
        d.model = "opus"
        let t = try TaskStore.create(d, project: project, existing: [])
        #expect(t.taskID == "OPS-1" && t.projectID == project.id)
        #expect(t.title == "Починить деплой" && t.model == "opus" && t.status == .new)
        let loaded = try #require(TaskStore.load(project).first)
        #expect(loaded.title == "Починить деплой")
        #expect(loaded.body.contains("Деплой."))
        #expect(loaded.model == "opus" && loaded.worktree == nil)
    }
}
