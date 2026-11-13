import Foundation

/// Git operations Artel needs: worktrees per task and committing `.artel/`.
public struct Git: Sendable {
    public let executable: String
    public let environment: [String: String]

    public init(executable: String, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    @discardableResult
    func git(_ args: [String], in dir: String) throws -> ProcessResult {
        try Shell.run(executable, ["-C", dir] + args, environment: environment, timeout: 60)
    }

    func check(_ r: ProcessResult, _ what: String) throws {
        guard r.ok else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArtelError.git("\(what): \(msg)")
        }
    }

    public func currentBranch(_ repo: String) -> String? {
        guard let r = try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repo), r.ok else { return nil }
        let b = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    public func hasCommits(_ repo: String) -> Bool {
        (try? git(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo))?.ok ?? false
    }

    func branchExists(_ branch: String, repo: String) -> Bool {
        (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo))?.ok ?? false
    }

    /// Creates (or reuses) the task's worktree. The task folder (`taskDir`, `.artel`) is excluded via sparse-checkout so the agent
    /// can't edit a stale copy of the task files and merges never conflict on them.
    public func ensureWorktree(repo: String, path: String, branch: String, base: String, taskDir: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return }
        guard hasCommits(repo) else {
            throw ArtelError.git("в репозитории нет ни одного коммита — сделайте первый коммит, чтобы создавать worktree")
        }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = try? git(["worktree", "prune"], in: repo)
        if branchExists(branch, repo: repo) {
            try check(git(["worktree", "add", path, branch], in: repo), "git worktree add")
        } else {
            try check(git(["worktree", "add", "-b", branch, path, base], in: repo), "git worktree add")
        }
        try check(git(["sparse-checkout", "set", "--no-cone", "/*", "!/\(taskDir)/"], in: path), "git sparse-checkout")
    }

    /// `git status --porcelain` limited to the task folder (`taskDir`, `.artel`).
    public func artelChanges(repo: String, taskDir: String) -> [String] {
        guard let r = try? git(["status", "--porcelain", "--untracked-files=all", "--", taskDir], in: repo), r.ok else { return [] }
        return r.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Commits only the task folder (`taskDir`, `.artel`), leaving whatever else the operator staged untouched.
    public func commitArtel(repo: String, taskDir: String, message: String) throws {
        try check(git(["add", "--all", "--", taskDir], in: repo), "git add")
        try check(git(["commit", "--only", "-m", message, "--", taskDir], in: repo), "git commit")
    }

    public func isIgnored(_ path: String, repo: String) -> Bool {
        (try? git(["check-ignore", "-q", path], in: repo))?.ok ?? false
    }
}

/// Where a task's worktree lives: `~/.artel/worktrees/<project>-<short id>/<TASK>`.
public enum WorktreeLayout {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["ARTEL_WORKTREES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".artel/worktrees", isDirectory: true)
    }

    public static func path(project: Project, taskID: String) -> String {
        let folder = "\(TaskStore.slug(project.name, maxLength: 30))-\(project.id.uuidString.prefix(4).lowercased())"
        return root.appendingPathComponent(folder).appendingPathComponent(taskID).path
    }

    public static func branch(for task: ArtelTask) -> String {
        "artel/\(task.taskID)-\(TaskStore.slug(task.title, maxLength: 30))"
    }
}

/// Keeps the project's `.gitignore` in line with the "store .artel in git" setting.
public enum ArtelGitignore {
    public static func apply(storeInGit: Bool, project: Project) throws {
        let line = "/\(TaskStore.dirName(project))/"
        let url = project.url.appendingPathComponent(".gitignore")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let has = lines.contains { $0.trimmingCharacters(in: .whitespaces) == line }
        if storeInGit && has {
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == line }
        } else if !storeInGit && !has {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            lines.append(line)
            lines.append("")
        } else {
            return
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
