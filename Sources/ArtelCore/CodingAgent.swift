import Foundation

public struct AgentModel: Identifiable, Hashable, Sendable {
    /// Value passed to the CLI; nil = the agent's own default.
    public var id: String?
    public var title: String
    public init(id: String?, title: String) {
        self.id = id
        self.title = title
    }
}

/// Everything needed to start (or resume) an agent process.
public struct LaunchSpec: Equatable, Sendable {
    public var executable: String
    public var name: String
    public var model: String?
    public var permissionMode: String
    public var settingsFile: String
    /// Start a new conversation with this id, or resume it.
    public var conversationID: String
    public var resume: Bool
    public var initialPrompt: String?
    /// Extra directories the agent may access (task folder outside the worktree).
    public var addDirs: [String]

    public init(executable: String, name: String, model: String?, permissionMode: String, settingsFile: String,
                conversationID: String, resume: Bool, initialPrompt: String? = nil, addDirs: [String] = []) {
        self.addDirs = addDirs
        self.executable = executable
        self.name = name
        self.model = model
        self.permissionMode = permissionMode
        self.settingsFile = settingsFile
        self.conversationID = conversationID
        self.resume = resume
        self.initialPrompt = initialPrompt
    }
}

/// A terminal coding agent. Ships Claude Code and Kimi Code; others plug in here.
public protocol CodingAgent: Sendable {
    static var id: String { get }
    var displayName: String { get }
    var executableName: String { get }
    var models: [AgentModel] { get }
    var permissionModes: [String] { get }
    func command(for spec: LaunchSpec) -> [String]
    /// Whether a conversation can be resumed (it has a transcript on disk).
    func canResume(conversationID: String, transcriptPath: String?, cwd: String) -> Bool
}

public extension CodingAgent {
    /// Instance access to the static id (handy for `any CodingAgent` existentials).
    var agentID: String { Self.id }
}

public struct ClaudeCodeAgent: CodingAgent {
    public static let id = "claude"
    public let displayName = "Claude Code"
    public let executableName = "claude"
    public let models = [
        AgentModel(id: nil, title: "Default"),
        AgentModel(id: "opus", title: "Opus"),
        AgentModel(id: "sonnet", title: "Sonnet"),
        AgentModel(id: "haiku", title: "Haiku"),
    ]
    public let permissionModes = ["auto", "manual", "acceptEdits", "plan", "dontAsk", "bypassPermissions"]

    public init() {}

    public func command(for spec: LaunchSpec) -> [String] {
        var cmd = [spec.executable, "--settings", spec.settingsFile, "--permission-mode", spec.permissionMode,
                   "--name", spec.name]
        if let model = spec.model, !model.isEmpty { cmd += ["--model", model] }
        // Variadic flags: keep them before other options so they never swallow the prompt.
        for dir in spec.addDirs { cmd += ["--add-dir", dir] }
        cmd += spec.resume ? ["--resume", spec.conversationID] : ["--session-id", spec.conversationID]
        if let prompt = spec.initialPrompt, !prompt.isEmpty, !spec.resume { cmd.append(prompt) }
        return cmd
    }

    public func canResume(conversationID: String, transcriptPath: String?, cwd: String) -> Bool {
        let fm = FileManager.default
        if let transcriptPath, fm.fileExists(atPath: transcriptPath) { return true }
        return fm.fileExists(atPath: Self.transcriptURL(conversationID: conversationID, cwd: cwd).path)
    }

    /// `~/.claude/projects/<cwd with / and . replaced by ->/<id>.jsonl`
    public static func transcriptURL(conversationID: String, cwd: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        let configDir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let encoded = cwd.map { ($0 == "/" || $0 == ".") ? "-" : String($0) }.joined()
        return configDir.appendingPathComponent("projects/\(encoded)/\(conversationID).jsonl")
    }

    /// Settings passed via `--settings`: Artel's hooks only. They merge with the user's own settings.
    public static func hookSettings(hookBinary: String) throws -> Data {
        let command = "'\(hookBinary.replacingOccurrences(of: "'", with: "'\\''"))'"
        let handler: [[String: Any]] = [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                      "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
        var hooks: [String: Any] = [:]
        for e in events { hooks[e] = handler }
        let settings: [String: Any] = ["hooks": hooks]
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
}

/// Kimi Code CLI (`kimi`).
///
/// Integration differs from Claude Code: there is no `--settings` — hooks are read from
/// `~/.kimi-code/config.toml` (a block Artel maintains itself). A new session id is assigned by kimi
/// itself; Artel learns it from the SessionStart hook. An initial prompt is not passed in argv
/// (interactive kimi doesn't accept one): Artel pastes it into the TUI once the session is ready.
public struct KimiCodeAgent: CodingAgent {
    public static let id = "kimi"
    public let displayName = "Kimi Code"
    public let executableName = "kimi"
    public let models = [
        AgentModel(id: nil, title: "Default"),
        AgentModel(id: "kimi-code/kimi-for-coding", title: "Kimi for Coding"),
        AgentModel(id: "kimi-code/kimi-for-coding-highspeed", title: "Kimi for Coding (highspeed)"),
        AgentModel(id: "kimi-code/k3", title: "K3"),
        AgentModel(id: "kimi-code/k3-256k", title: "K3 256K"),
        AgentModel(id: "kimi-code/k3.1-pro", title: "K3.1 Pro"),
        AgentModel(id: "kimi-code/k3.1-pro-highspeed", title: "K3.1 Pro (highspeed)"),
    ]
    /// `auto` → Never Ask, `yolo` → Ask When Needed, `plan` → Plan mode; anything else = ask by default.
    public let permissionModes = ["auto", "yolo", "plan"]

    public init() {}

    public func command(for spec: LaunchSpec) -> [String] {
        var cmd = [spec.executable]
        switch spec.permissionMode {
        case "auto": cmd.append("--auto")
        case "yolo", "dontAsk": cmd.append("--yolo")
        case "plan": cmd.append("--plan")
        default: break
        }
        if let model = spec.model, !model.isEmpty { cmd += ["--model", model] }
        // Variadic flags before other options so they never swallow anything.
        for dir in spec.addDirs { cmd += ["--add-dir", dir] }
        // Resume by the id learned from the SessionStart hook; a fresh session gets no id flag.
        if spec.resume { cmd += ["--session", spec.conversationID] }
        return cmd
    }

    public func canResume(conversationID: String, transcriptPath: String?, cwd: String) -> Bool {
        Self.hasSession(conversationID, indexURL: Self.sessionIndexURL())
    }

    /// kimi keeps its session list in `session_index.jsonl` (one `{"sessionId": …}` object per line).
    public static func hasSession(_ conversationID: String, indexURL: URL?) -> Bool {
        guard let indexURL, !conversationID.isEmpty,
              let text = try? String(contentsOf: indexURL, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["sessionId"] as? String == conversationID else { continue }
            return true
        }
        return false
    }

    // MARK: - kimi home & config.toml

    public static func home() -> URL {
        if let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
    }

    public static func configURL() -> URL { home().appendingPathComponent("config.toml") }
    public static func sessionIndexURL() -> URL { home().appendingPathComponent("session_index.jsonl") }

    // MARK: - Managed config block (hooks)

    static let configBegin = "# >>> artel"
    static let configEnd = "# <<< artel"

    /// Hook events Artel subscribes to in kimi. `Notification` is background-task noise for kimi
    /// (unlike Claude's operator notifications) and is ignored by the status state machine.
    static let hookEvents = ["SessionStart", "TurnStarted", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                             "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
                             "Interrupt", "SessionEnd"]

    public static func configBlock(hookBinary: String) -> String {
        let command = tomlString("'\(hookBinary.replacingOccurrences(of: "'", with: "'\\''"))'")
        var lines = [configBegin,
                     "# Managed by Artel: session status hooks.",
                     "# Change it only through Artel; the whole block may be removed."]
        for event in hookEvents {
            lines += ["", "[[hooks]]", "event = \"\(event)\"", "command = \(command)", "timeout = 5"]
        }
        lines += ["", configEnd]
        return lines.joined(separator: "\n")
    }

    /// Inserts or updates Artel's block in kimi's `config.toml` (atomic write).
    public static func installConfig(hookBinary: String, to url: URL = configURL()) throws {
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = configBlock(hookBinary: hookBinary) + "\n"
        // A block written by Aide (the old name) is replaced in place, or dropped next to a current one.
        if let legacy = managedBlockRange(in: existing, begin: LegacyAide.kimiConfigBegin, end: LegacyAide.kimiConfigEnd) {
            if managedBlockRange(in: existing) == nil {
                existing.replaceSubrange(legacy, with: configBegin + configEnd)
            } else {
                existing.removeSubrange(legacy)
            }
        }
        let result: String
        if let range = managedBlockRange(in: existing) {
            result = existing.replacingCharacters(in: range, with: block)
        } else {
            var base = existing
            while base.hasSuffix("\n") { base.removeLast() }
            result = base.isEmpty ? block : base + "\n\n" + block
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try result.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func managedBlockRange(in text: String, begin beginMarker: String = configBegin,
                                  end endMarker: String = configEnd) -> Range<String.Index>? {
        guard let begin = text.range(of: beginMarker), let end = text.range(of: endMarker),
              begin.lowerBound <= end.lowerBound else { return nil }
        return begin.lowerBound..<end.upperBound
    }

    static func tomlString(_ s: String) -> String {
        var out = "\""
        for ch in s {
            if ch == "\\" { out += "\\\\" }
            else if ch == "\"" { out += "\\\"" }
            else { out.append(ch) }
        }
        return out + "\""
    }
}

/// Available agents and lookup by id (tolerant of unknown ids from old state files and task.md).
public enum CodingAgents {
    public static let all: [any CodingAgent] = [ClaudeCodeAgent(), KimiCodeAgent()]

    public static func agent(forID id: String?) -> any CodingAgent {
        let wanted = id ?? ClaudeCodeAgent.id
        return all.first { $0.agentID == wanted } ?? ClaudeCodeAgent()
    }
}
