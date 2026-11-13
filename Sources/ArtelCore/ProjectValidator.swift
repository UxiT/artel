import Foundation

/// What a folder lacks to use everything Artel offers. Only `notADirectory` blocks adding a project: without git there
/// are no task worktrees and diffs, without a filled CLAUDE.md Claude Code starts with no project description.
public enum ProjectValidator {
    public enum Issue: Equatable, Sendable {
        case notADirectory
        case notAGitRepository
        case missingClaudeMD
        case emptyClaudeMD
    }

    public static func issues(at url: URL) -> [Issue] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [.notADirectory] }
        var result: [Issue] = []
        if !isGitRepository(url) { result.append(.notAGitRepository) }
        let claudeMD = url.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMD.path) {
            result.append(.missingClaudeMD)
        } else if let text = try? String(contentsOf: claudeMD, encoding: .utf8), !hasDescription(text) {
            result.append(.emptyClaudeMD)
        }
        return result
    }

    /// The folder is the root of a git repository. `.git` is a directory in a normal clone and a file in a
    /// worktree/submodule. Checked live, not stored: the operator may run `git init` after adding the project.
    public static func isGitRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// The description is "filled" when there is real text besides headings, comments and template hints.
    public static func hasDescription(_ markdown: String) -> Bool {
        var inComment = false
        for raw in markdown.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                inComment = false
            }
            while let start = line.range(of: "<!--") {
                if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inComment = true
                }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "-" || line == "*" { continue }
            return true
        }
        return false
    }

    public static func claudeMDTemplate(projectName: String) -> String {
        """
        # \(projectName)

        ## Описание
        <!-- Обязательно: что это за проект, для кого и зачем. -->

        ## Стек
        <!-- Языки, фреймворки, ключевые библиотеки. Подробности — в docs/stack.md -->

        ## Архитектура
        <!-- Основные модули и как они связаны. Подробности — в docs/arch.md -->

        ## Команды
        <!-- Как собрать, запустить, прогнать тесты и линтеры. -->

        ## Соглашения
        <!-- Стиль кода, правила коммитов, что агенту делать нельзя. -->
        """
    }
}

extension Project {
    /// Worktrees, diffs, the base branch and committing `.artel/` need git; without it tasks run in the project folder.
    public var isGitRepository: Bool { ProjectValidator.isGitRepository(url) }
}
