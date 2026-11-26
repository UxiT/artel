import Foundation
import Testing
@testable import ArtelCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artel-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct TaskFileFormat {
    let pid = UUID()
    let dir = URL(fileURLWithPath: "/tmp/x")

    @Test func roundTrip() throws {
        let t = ArtelTask(projectID: pid, directory: dir, taskID: "ARTEL-12", title: "Форма логина: \"v2\"",
                         status: .inProgress, model: "opus", branch: "artel/ARTEL-12-forma",
                         worktree: "/Users/me/.artel/worktrees/p/ARTEL-12", sessions: ["s1"],
                         created: Date(timeIntervalSince1970: 1_700_000_000), updated: Date(timeIntervalSince1970: 1_700_000_100),
                         body: "\n## Что сделать\nФорму.\n", extraFrontmatter: ["custom: 1"])
        let text = TaskFile.serialize(t, projectName: "artel")
        #expect(text.hasPrefix("---\nid: ARTEL-12\n"))
        #expect(text.contains("project: artel\n"))
        let back = try #require(TaskFile.parse(text, projectID: pid, directory: dir))
        #expect(back == t)
        #expect(!text.contains("priority") && !text.contains("review") && !text.contains("iteration"))
    }

    @Test func legacyWorkflowFieldsAreDroppedAndStatusesMapped() throws {
        let text = """
        ---
        id: ARTEL-3
        title: Старая
        status: plan-review
        priority: high
        depends_on: [ARTEL-1]
        review: auto
        testing: [autotests]
        iteration: 4
        awaiting_agent: true
        merge_conflict: true
        ---
        Тело
        """
        let t = try #require(TaskFile.parse(text, projectID: pid, directory: dir))
        #expect(t.status == .inProgress)
        #expect(t.extraFrontmatter.isEmpty)
        let rewritten = TaskFile.serialize(t, projectName: "p")
        for key in ["priority", "depends_on", "review:", "testing", "iteration", "awaiting_agent", "merge_conflict"] {
            #expect(!rewritten.contains(key))
        }
        for (raw, status) in [("new", TaskStatus.new), ("plan", .inProgress), ("review", .inProgress),
                              ("testing", .inProgress), ("done", .done), ("cancelled", .done)] {
            #expect(TaskStatus(stored: raw) == status)
        }
        #expect(TaskStatus(stored: "whatever") == nil)
        // History lines with old statuses still decode.
        let entry = try JSONDecoder().decode(TaskStatus.self, from: Data(#""plan-review""#.utf8))
        #expect(entry == .inProgress)
    }

    @Test func toleratesHandEditedFiles() throws {
        let text = """
        ---
        id: OPS-3
        title: 'Починить деплой'
        status: in-progress   # the agent is working
        owner: me
        ---
        Тело
        """
        let t = try #require(TaskFile.parse(text, projectID: pid, directory: dir))
        #expect(t.title == "Починить деплой")
        #expect(t.status == .inProgress)
        #expect(t.extraFrontmatter == ["owner: me"])
        #expect(t.body == "Тело")
    }

    @Test func rejectsFilesWithoutFrontmatterOrID() {
        #expect(TaskFile.parse("# просто текст", projectID: pid, directory: dir) == nil)
        #expect(TaskFile.parse("---\ntitle: x\n---\n", projectID: pid, directory: dir) == nil)
    }
}

@Suite struct TaskStoreTests {
    @Test func slugs() {
        #expect(TaskStore.slug("Форма логина") == "forma-logina")
        #expect(TaskStore.slug("  Fix: API v2!! ") == "fix-api-v2")
        #expect(TaskStore.slug("???") == "task")
        #expect(TaskStore.slug(String(repeating: "очень длинное ", count: 10)).count <= 40)
    }

    @Test func createLoadAndNumbering() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = Project(name: "p", path: root.path)
        let a = try TaskStore.create(project: project, title: "Первая", existing: [])
        #expect(a.taskID == "ARTEL-1")
        #expect(a.directory.lastPathComponent == "ARTEL-1-pervaa" || a.directory.lastPathComponent.hasPrefix("ARTEL-1-"))
        project.taskPrefix = "OPS"
        let b = try TaskStore.create(project: project, title: "Вторая", existing: [a])
        #expect(b.taskID == "OPS-2")  // numbering is shared across prefixes
        let loaded = TaskStore.load(project).sorted { $0.taskID < $1.taskID }
        #expect(loaded.map(\.taskID) == ["ARTEL-1", "OPS-2"])
        #expect(loaded[0].body.contains("## Acceptance criteria"))
        let ignore = try String(contentsOf: root.appendingPathComponent(".artel/.gitignore"), encoding: .utf8)
        #expect(ignore.contains("tasks/*/logs/"))
        #expect(TaskStore.fingerprint(project).count == 2)
    }

    @Test func referencesForDroppedFiles() throws {
        let root = try tempDir()
        let outside = try tempDir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let project = Project(name: "p", path: root.path)
        let task = try TaskStore.create(project: project, title: "T", existing: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let inProject = root.appendingPathComponent("src/main.swift")
        try "x".write(to: inProject, atomically: true, encoding: .utf8)
        #expect(try TaskStore.reference(for: inProject, project: project, task: task) == "@src/main.swift")

        let shot = outside.appendingPathComponent("shot.png")
        try Data([1, 2, 3]).write(to: shot)
        let ref1 = try TaskStore.reference(for: shot, project: project, task: task)
        let ref2 = try TaskStore.reference(for: shot, project: project, task: task)
        #expect(ref1.hasPrefix("![shot.png](attachments/shot.png) @/"))
        #expect(ref2.hasPrefix("![shot-2.png](attachments/shot-2.png)"))
        #expect(FileManager.default.fileExists(atPath: task.attachmentsDir.appendingPathComponent("shot-2.png").path))
    }
}

@Suite struct GitTests {
    let git = Git(executable: "/usr/bin/git", environment: ProcessInfo.processInfo.environment.merging([
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    ]) { $1 })

    func makeRepo() throws -> URL {
        let root = try tempDir()
        _ = try git.git(["init", "-q", "-b", "main"], in: root.path)
        try "code".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try git.git(["add", "-A"], in: root.path)
        _ = try git.git(["commit", "-qm", "init"], in: root.path)
        return root
    }

    @Test func worktreeExcludesArtelAndIsReusable() throws {
        let repo = try makeRepo()
        let wt = try tempDir().appendingPathComponent("wt/ARTEL-1")
        defer { try? FileManager.default.removeItem(at: repo) }
        let project = Project(name: "p", path: repo.path)
        _ = try TaskStore.create(project: project, title: "T", existing: [])
        try git.commitArtel(repo: repo.path, taskDir: ".artel", message: "artel: tasks")
        #expect(git.artelChanges(repo: repo.path, taskDir: ".artel").isEmpty)

        try git.ensureWorktree(repo: repo.path, path: wt.path, branch: "artel/ARTEL-1-t", base: "main", taskDir: ".artel")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: wt.appendingPathComponent("a.txt").path))
        #expect(!fm.fileExists(atPath: wt.appendingPathComponent(".artel").path))
        #expect(git.currentBranch(wt.path) == "artel/ARTEL-1-t")
        try git.ensureWorktree(repo: repo.path, path: wt.path, branch: "artel/ARTEL-1-t", base: "main", taskDir: ".artel")  // idempotent

        // Removed worktree with an existing branch is recreated from that branch.
        _ = try git.git(["worktree", "remove", "--force", wt.path], in: repo.path)
        try git.ensureWorktree(repo: repo.path, path: wt.path, branch: "artel/ARTEL-1-t", base: "main", taskDir: ".artel")
        #expect(git.currentBranch(wt.path) == "artel/ARTEL-1-t")
    }

    @Test func commitArtelLeavesOtherStagedChanges() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "changed".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try git.git(["add", "a.txt"], in: repo.path)
        let project = Project(name: "p", path: repo.path)
        _ = try TaskStore.create(project: project, title: "T", existing: [])
        #expect(!git.artelChanges(repo: repo.path, taskDir: ".artel").isEmpty)
        try git.commitArtel(repo: repo.path, taskDir: ".artel", message: "artel: ARTEL-1 created")
        #expect(git.artelChanges(repo: repo.path, taskDir: ".artel").isEmpty)
        let staged = try git.git(["diff", "--cached", "--name-only"], in: repo.path).stdout
        #expect(staged.trimmingCharacters(in: .whitespacesAndNewlines) == "a.txt")
    }

    @Test func emptyRepoGivesClearError() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try git.git(["init", "-q"], in: root.path)
        #expect(throws: ArtelError.self) {
            try git.ensureWorktree(repo: root.path, path: root.appendingPathComponent("wt").path, branch: "b", base: "main", taskDir: ".artel")
        }
    }

    @Test func gitignoreToggle() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "p", path: root.path)
        try "node_modules/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try ArtelGitignore.apply(storeInGit: false, project: project)
        try ArtelGitignore.apply(storeInGit: false, project: project)
        var text = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(text == "node_modules/\n/.artel/\n")
        try ArtelGitignore.apply(storeInGit: true, project: project)
        text = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(text == "node_modules/\n")
    }
}

@Suite struct PromptTests {
    @Test func promptHasTaskPathsAndBody() {
        let project = Project(name: "artel", path: "/p")
        var task = ArtelTask(projectID: project.id, directory: URL(fileURLWithPath: "/p/.artel/tasks/ARTEL-1-x"),
                            taskID: "ARTEL-1", title: "X", body: "\n## What to do\nA button.\n")
        let inProject = TaskPrompt.build(task: task, project: project, worktree: nil)
        #expect(inProject.hasPrefix("Task ARTEL-1 \"X\" of project artel."))
        #expect(inProject.contains("/p/.artel/tasks/ARTEL-1-x"))
        #expect(!inProject.contains("worktree"))
        #expect(!inProject.contains("mcp__aide"))
        #expect(inProject.hasSuffix("## What to do\nA button."))

        task.branch = "artel/ARTEL-1-x"
        let inWorktree = TaskPrompt.build(task: task, project: project, worktree: "/wt/ARTEL-1")
        #expect(inWorktree.contains("git worktree (/wt/ARTEL-1, branch artel/ARTEL-1-x)"))
    }

    @Test func obsoleteFramesAreDetected() {
        #expect(!PromptTemplate.isObsolete(PromptTemplate.defaultFrame))
        #expect(PromptTemplate.isObsolete("{{reason}}\n{{task_body}}"))
        #expect(PromptTemplate.isObsolete("Используй mcp__aide__set_status"))
        #expect(PromptTemplate.isObsolete("{{#stage}}x{{/stage}}"))
    }

    @Test func addDirsInCommand() {
        let spec = LaunchSpec(executable: "c", name: "n", model: nil, permissionMode: "auto", settingsFile: "s",
                              conversationID: "id", resume: false, initialPrompt: "p", addDirs: ["/t"])
        #expect(ClaudeCodeAgent().command(for: spec).contains(["--add-dir", "/t"]))
        #expect(ClaudeCodeAgent().command(for: spec).last == "p")
    }
}

@Suite struct DiffTests {
    let git = Git(executable: "/usr/bin/git", environment: ProcessInfo.processInfo.environment.merging([
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    ]) { $1 })

    /// Repo with a.txt on main and a task worktree on branch "task".
    func setUp() throws -> (repo: String, wt: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artel-m-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try git.git(["init", "-q", "-b", "main"], in: repo)
        try "one\ntwo\nthree\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        _ = try git.git(["add", "-A"], in: repo)
        _ = try git.git(["commit", "-qm", "init"], in: repo)
        let wt = root.appendingPathComponent("wt").path
        try git.ensureWorktree(repo: repo, path: wt, branch: "task", base: "main", taskDir: ".artel")
        return (repo, wt)
    }

    @Test func diffIncludesCommittedUncommittedAndUntracked() throws {
        let (_, wt) = try setUp()
        try "one\nTWO\nthree\n".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: wt + "/b.txt", atomically: true, encoding: .utf8)
        var files = try git.taskDiff(worktree: wt, base: "main")
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        #expect(files[0].kind == .modified && files[0].additions == 1 && files[0].deletions == 1)
        #expect(files[1].kind == .added && files[1].additions == 1)
        _ = try git.git(["add", "-A"], in: wt)
        _ = try git.git(["commit", "-qm", "work"], in: wt)
        files = try git.taskDiff(worktree: wt, base: "main")
        #expect(files.map(\.path) == ["a.txt", "b.txt"])  // still visible after commit
    }

    @Test func removesWorktreeAndMergedBranch() throws {
        let (repo, wt) = try setUp()
        try git.removeWorktree(repo: repo, path: wt)
        #expect(!FileManager.default.fileExists(atPath: wt))
        try git.deleteBranch(repo: repo, branch: "task", force: false)  // nothing on it → merged
        #expect(!git.branchExists("task", repo: repo))
        try git.removeWorktree(repo: repo, path: wt)  // already gone: no error
    }

    @Test func parsesRenamesAndDeletes() {
        let text = """
        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let files = Git.parseUnifiedDiff(text)
        #expect(files.map(\.kind) == [.renamed, .deleted])
        #expect(files[0].path == "new.txt" && files[1].path == "gone.txt" && files[1].deletions == 1)
    }
}

@Suite struct EditorChoice {
    func project(_ files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artel-ed-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try "".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        return dir
    }

    let installed: Set<String> = ["com.jetbrains.goland", "com.jetbrains.rustrover", "com.jetbrains.WebStorm", "com.jetbrains.PhpStorm"]

    @Test func picksIDEByStack() throws {
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["go.mod"]), installed: installed) == "com.jetbrains.goland")
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["Cargo.toml"]), installed: installed) == "com.jetbrains.rustrover")
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["composer.json", "package.json"]), installed: installed) == "com.jetbrains.PhpStorm")
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["package.json"]), installed: installed) == "com.jetbrains.WebStorm")
    }

    @Test func asksWhenNothingFits() throws {
        // Swift package: no matching JetBrains IDE installed, no IntelliJ either → operator decides.
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["Package.swift"]), installed: installed) == nil)
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["requirements.txt"]), installed: installed) == nil)
        // IntelliJ Ultimate is the universal fallback when present.
        #expect(JetBrainsIDE.autoChoice(forProjectAt: try project(["Package.swift"]), installed: ["com.jetbrains.intellij"]) == "com.jetbrains.intellij")
    }

    @Test func nonEditorsAreExcluded() {
        #expect(!JetBrainsIDE.isCodeEditor("com.jetbrains.toolbox"))
        #expect(!JetBrainsIDE.isCodeEditor("com.jetbrains.datagrip"))
        #expect(JetBrainsIDE.isCodeEditor("com.jetbrains.goland"))
    }
}
