import Foundation
import Testing
@testable import ArtelCore

struct KimiAgentTests {
    private func spec(permissionMode: String = "auto", model: String? = "kimi-code/k3",
                      conversationID: String = "x", resume: Bool = false, prompt: String? = nil,
                      addDirs: [String] = ["/tmp/t"]) -> LaunchSpec {
        LaunchSpec(executable: "/usr/bin/kimi", name: "s", model: model, permissionMode: permissionMode,
                   settingsFile: "/tmp/settings.json", conversationID: conversationID, resume: resume,
                   initialPrompt: prompt, addDirs: addDirs)
    }

    @Test func freshSessionCommand() {
        let cmd = KimiCodeAgent().command(for: spec(prompt: "сделай план"))
        #expect(cmd.first == "/usr/bin/kimi")
        #expect(cmd.contains("--auto"))
        #expect(cmd.contains(["--model", "kimi-code/k3"]))
        #expect(cmd.contains(["--add-dir", "/tmp/t"]))
        #expect(!cmd.contains("--session"))
        #expect(!cmd.contains("--settings"))
        #expect(!cmd.contains("сделай план"))  // промпт не идёт в argv — вставляется в TUI
    }

    @Test func resumeCommandUsesSessionFlag() {
        let cmd = KimiCodeAgent().command(for: spec(conversationID: "abc", resume: true))
        #expect(cmd.contains(["--session", "abc"]))
        #expect(!cmd.contains("--model") == false)  // модель остаётся при resume
    }

    @Test func permissionModesMapToFlags() {
        #expect(KimiCodeAgent().command(for: spec(permissionMode: "yolo")).contains("--yolo"))
        #expect(KimiCodeAgent().command(for: spec(permissionMode: "plan")).contains("--plan"))
        let manual = KimiCodeAgent().command(for: spec(permissionMode: "manual"))
        #expect(!manual.contains("--auto") && !manual.contains("--yolo") && !manual.contains("--plan"))
    }

    @Test func registryResolvesAgents() {
        #expect(CodingAgents.agent(forID: nil).agentID == ClaudeCodeAgent.id)
        #expect(CodingAgents.agent(forID: "kimi").agentID == "kimi")
        #expect(CodingAgents.agent(forID: "unknown").agentID == ClaudeCodeAgent.id)
    }

    @Test func augmentedPathIncludesKimiInstallerDirectory() {
        let path = ShellEnvironment.augmentedPath("/usr/bin:/bin")
        let kimiBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/bin").path
        #expect(path.split(separator: ":").contains(Substring(kimiBin)))
    }

    @Test func configBlockHasHooksOnly() {
        let block = KimiCodeAgent.configBlock(hookBinary: "/opt/Artel/bin/artel-hook")
        #expect(block.contains("# >>> artel") && block.contains("# <<< artel"))
        #expect(block.contains("event = \"SessionStart\""))
        #expect(block.contains("event = \"Stop\""))
        #expect(block.contains("event = \"Interrupt\""))
        #expect(block.contains("command = \"'/opt/Artel/bin/artel-hook'\""))
        #expect(!block.contains("mcp__") && !block.contains("permission.rules"))
    }

    @Test func configBlockShellQuotesHookPath() {
        let block = KimiCodeAgent.configBlock(hookBinary: "/Users/me/Library/Application Support/Artel's/bin/artel-hook")
        #expect(block.contains("command = \"'/Users/me/Library/Application Support/Artel'\\\\''s/bin/artel-hook'\""))
    }

    @Test func installConfigCreatesAndUpdatesBlock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try "# моя настройка\n".write(to: url, atomically: true, encoding: .utf8)

        try KimiCodeAgent.installConfig(hookBinary: "/a/artel-hook", to: url)
        try KimiCodeAgent.installConfig(hookBinary: "/b/artel-hook", to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("command = \"'/b/artel-hook'\""))
        #expect(!text.contains("'/a/artel-hook'"))
        #expect(text.contains("# моя настройка"))
        #expect(text.components(separatedBy: "# >>> artel").count == 2)
    }

    @Test func installConfigCreatesFileInEmptyDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try KimiCodeAgent.installConfig(hookBinary: "/artel-hook", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("# >>> artel"))
    }

    @Test func hasSessionFindsIdInIndex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session_index.jsonl")
        try "{\"sessionId\":\"s-1\",\"workDir\":\"/a\"}\n{\"sessionId\":\"s-2\",\"workDir\":\"/b\"}\n"
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(KimiCodeAgent.hasSession("s-1", indexURL: url))
        #expect(KimiCodeAgent.hasSession("s-2", indexURL: url))
        #expect(!KimiCodeAgent.hasSession("s-3", indexURL: url))
        #expect(!KimiCodeAgent.hasSession("s-1", indexURL: nil))
    }

    @Test func obsoletePromptFrameIsDroppedOnDecode() throws {
        let data = Data(#"{"promptFrame": "{{reason}} mcp__aide__get_task {{task_body}}"}"#.utf8)
        #expect(try JSONDecoder.artel.decode(AppSettings.self, from: data).promptFrame == nil)
        let custom = Data(#"{"promptFrame": "Сделай: {{task_body}}"}"#.utf8)
        #expect(try JSONDecoder.artel.decode(AppSettings.self, from: custom).promptFrame == "Сделай: {{task_body}}")
    }

    @Test func legacyDefaultModelMigratesToClaude() throws {
        let data = "{\"defaultModel\": \"opus\"}".data(using: .utf8)!
        let settings = try JSONDecoder.artel.decode(AppSettings.self, from: data)
        #expect(settings.defaultModel(for: ClaudeCodeAgent.id) == "opus")
        #expect(settings.defaultModel(for: KimiCodeAgent.id) == nil)
        // и новое состояние кодируется без легаси-ключа
        let encoded = try JSONEncoder.artel.encode(settings)
        #expect(!(String(data: encoded, encoding: .utf8) ?? "").contains("defaultModel\""))
    }

    @Test func perAgentDefaultModelsRoundTrip() throws {
        var settings = AppSettings()
        settings.defaultModels[KimiCodeAgent.id] = "kimi-code/k3"
        let decoded = try JSONDecoder.artel.decode(AppSettings.self, from: JSONEncoder.artel.encode(settings))
        #expect(decoded.defaultModel(for: KimiCodeAgent.id) == "kimi-code/k3")
    }

    @Test func stateMachineHandlesKimiEvents() {
        var status = SessionStatus(activity: .ready)
        status = status.applying(HookEvent(artelSessionID: "a", name: "TurnStarted", clientType: "kimi_code_cli"))
        #expect(status.activity == .working)
        // Фоновые задачи kimi (Notification) не переводят сессию в «ждёт ответа».
        status = status.applying(HookEvent(artelSessionID: "a", name: "Notification",
                                           notificationType: "task.completed", clientType: "kimi_code_cli"))
        #expect(status.activity == .working)
        status = status.applying(HookEvent(artelSessionID: "a", name: "Interrupt", clientType: "kimi_code_cli"))
        #expect(status.activity == .ready)
        // Уведомления Claude Code работают как раньше.
        var claude = SessionStatus(activity: .working)
        claude = claude.applying(HookEvent(artelSessionID: "a", name: "Notification",
                                           notificationType: "elicitation_dialog", message: "вопрос"))
        #expect(claude.activity == .waitingInput)
    }
}
