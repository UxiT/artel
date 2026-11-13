import Foundation

public struct FileDiff: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public enum Kind: String, Sendable { case added, modified, deleted, renamed }
    public var kind: Kind
    public var additions: Int
    public var deletions: Int
    /// Unified diff text for this file.
    public var patch: String
}

extension Git {
    // MARK: Diff

    /// Everything the task changed relative to where its branch left `base`: commits on the branch,
    /// uncommitted edits and untracked files in the worktree.
    public func taskDiff(worktree: String, base: String) throws -> [FileDiff] {
        let mb = try git(["merge-base", "HEAD", base], in: worktree)
        try check(mb, "git merge-base")
        let baseCommit = mb.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracked = try git(["diff", "--no-color", "--no-ext-diff", "-M", baseCommit], in: worktree)
        try check(tracked, "git diff")
        var files = Self.parseUnifiedDiff(tracked.stdout)
        let untracked = try git(["ls-files", "--others", "--exclude-standard"], in: worktree)
        for path in untracked.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            // --no-index exits 1 when files differ; that's the normal case here.
            let r = try git(["diff", "--no-color", "--no-index", "--", "/dev/null", path], in: worktree)
            files += Self.parseUnifiedDiff(r.stdout).map { var f = $0; f.path = path; f.kind = .added; return f }
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func parseUnifiedDiff(_ text: String) -> [FileDiff] {
        var out: [FileDiff] = []
        var current: [Substring] = []
        func flush() {
            guard let header = current.first else { return }
            var path = ""
            var kind = FileDiff.Kind.modified
            var add = 0, del = 0
            // "diff --git a/x b/y"
            if let range = header.range(of: " b/", options: .backwards) { path = String(header[range.upperBound...]) }
            for line in current.dropFirst() {
                if line.hasPrefix("new file mode") { kind = .added }
                else if line.hasPrefix("deleted file mode") { kind = .deleted }
                else if line.hasPrefix("rename to ") { kind = .renamed; path = String(line.dropFirst("rename to ".count)) }
                else if line.hasPrefix("+++ b/") { path = String(line.dropFirst(6)) }
                else if line.hasPrefix("+") && !line.hasPrefix("+++") { add += 1 }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { del += 1 }
            }
            out.append(FileDiff(path: path, kind: kind, additions: add, deletions: del,
                                patch: current.joined(separator: "\n")))
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush() }
            if !current.isEmpty || line.hasPrefix("diff --git ") { current.append(line) }
        }
        flush()
        return out
    }

    // MARK: Worktree cleanup

    public func removeWorktree(repo: String, path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            _ = try? git(["worktree", "prune"], in: repo)
            return
        }
        try check(git(["worktree", "remove", "--force", path], in: repo), "git worktree remove")
    }

    public func deleteBranch(repo: String, branch: String, force: Bool) throws {
        try check(git(["branch", force ? "-D" : "-d", branch], in: repo), "git branch -d")
    }
}
