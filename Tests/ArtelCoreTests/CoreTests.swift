import Foundation
import Testing
@testable import ArtelCore

private func event(_ name: String, _ fields: [String: Any] = [:]) -> HookEvent {
    var raw: [String: Any] = ["hook_event_name": name, "session_id": "conv-1", "cwd": "/tmp/p"]
    raw.merge(fields) { $1 }
    let data = try! JSONSerialization.data(withJSONObject: raw)
    return HookEvent.fromRawHookInput(data, artelSessionID: "s1")!
}

private func fold(_ events: [HookEvent]) -> SessionStatus {
    events.reduce(SessionStatus()) { $0.applying($1) }
}

@Suite struct HookEventParsing {
    @Test func dropsLargeToolPayloadsAndSummarizes() {
        let e = event("PreToolUse", [
            "tool_name": "Write",
            "tool_input": ["file_path": "/src/a.swift", "content": String(repeating: "x", count: 100_000)],
            "tool_response": ["ok": true],
        ])
        #expect(e.toolSummary == "/src/a.swift")
        let encoded = try! JSONEncoder.artel.encode(e)
        #expect(encoded.count < 1000)
    }

    @Test func extractsAskUserQuestion() {
        let e = event("PreToolUse", [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Какую БД использовать?", "options": []]]],
        ])
        #expect(e.toolSummary == "Какую БД использовать?")
    }

    @Test func rejectsGarbage() {
        #expect(HookEvent.fromRawHookInput(Data("nope".utf8), artelSessionID: "s") == nil)
        #expect(HookEvent.fromRawHookInput(Data("{}".utf8), artelSessionID: "s") == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let e = event("Stop", ["last_assistant_message": "Готово"])
        let back = try JSONDecoder.artel.decode(HookEvent.self, from: JSONEncoder.artel.encode(e))
        #expect(back.name == "Stop")
        #expect(back.lastAssistantMessage == "Готово")
        #expect(back.claudeSessionID == "conv-1")
    }
}

@Suite struct SessionStateMachine {
    @Test func normalTurn() {
        let s = fold([
            event("SessionStart", ["source": "startup"]),
            event("UserPromptSubmit", ["prompt": "Сделай форму"]),
            event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
        ])
        #expect(s.activity == .working)
        #expect(s.detail == "Bash: npm test")
        #expect(s.message == "Сделай форму")
        #expect(s.claudeSessionID == "conv-1")

        let done = s.applying(event("Stop", ["last_assistant_message": "Форма готова, тесты зелёные."]))
        #expect(done.activity == .idle)
        #expect(done.message == "Форма готова, тесты зелёные.")
        #expect(done.detail == nil)
    }

    @Test func stopWithQuestionWaitsForInput() {
        let s = fold([event("UserPromptSubmit"), event("Stop", ["last_assistant_message": "План готов.\n\nПродолжать?"])])
        #expect(s.activity == .waitingInput)
        #expect(s.activity.needsAttention)
    }

    @Test func askUserQuestionThenAnswer() {
        var s = fold([
            event("UserPromptSubmit"),
            event("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "React или Vue?"]]]]),
        ])
        #expect(s.activity == .waitingInput)
        #expect(s.message == "React или Vue?")
        s = s.applying(event("PostToolUse", ["tool_name": "AskUserQuestion"]))
        #expect(s.activity == .working)
        #expect(s.message == nil)
    }

    @Test func askUserQuestionPermissionStaysQuestion() {
        let s = fold([
            event("UserPromptSubmit"),
            event("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Swift или Go?"]]]]),
            event("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Swift или Go?"]]]]),
            event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]),
        ])
        #expect(s.activity == .waitingInput)
        #expect(s.message == "Swift или Go?")
    }

    @Test func permissionFlow() {
        var s = fold([
            event("UserPromptSubmit"),
            event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]),
            event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]),
        ])
        #expect(s.activity == .waitingPermission)
        #expect(s.message == "Bash: rm -rf build")
        s = s.applying(event("PostToolUse", ["tool_name": "Bash"]))
        #expect(s.activity == .working)
    }

    @Test func idleNotificationDoesNotChangeState() {
        let s = fold([event("Stop", ["last_assistant_message": "Готово."]),
                      event("Notification", ["notification_type": "idle_prompt", "message": "waiting"])])
        #expect(s.activity == .idle)
        #expect(s.message == "Готово.")
    }

    @Test func clearKeepsProcessAliveAndUpdatesConversation() {
        var s = fold([event("Stop"), event("SessionEnd", ["reason": "clear"])])
        #expect(s.activity == .idle)
        #expect(s.applying(event("SessionStart", ["source": "clear"])).activity == .ready)
        var raw = event("SessionStart", ["source": "clear"])
        raw.claudeSessionID = "conv-2"
        s = s.applying(raw)
        #expect(s.claudeSessionID == "conv-2")
        #expect(s.applying(event("SessionEnd", ["reason": "prompt_input_exit", "session_id": "conv-2"])).activity == .exited)
    }

    @Test func kimiClearIgnoresPreviousSessionEnd() {
        let s = fold([
            event("SessionStart", ["source": "startup"]),
            event("UserPromptSubmit"),
            event("Stop"),
            event("SessionStart", ["source": "startup", "session_id": "conv-2"]),
            event("SessionEnd", ["reason": "exit", "session_id": "conv-1"]),
        ])
        #expect(s.activity == .ready)
        #expect(s.claudeSessionID == "conv-2")
    }

    @Test func stopFailureIsError() {
        let s = fold([event("UserPromptSubmit"), event("StopFailure", ["message": "overloaded"])])
        #expect(s.activity == .error)
        #expect(s.message == "overloaded")
    }

    @Test func sinceChangesOnlyOnTransition() {
        var a = event("UserPromptSubmit"); a.timestamp = Date(timeIntervalSince1970: 100)
        var b = event("PreToolUse", ["tool_name": "Read"]); b.timestamp = Date(timeIntervalSince1970: 200)
        let s = fold([a, b])
        #expect(s.since == Date(timeIntervalSince1970: 100))
    }

    @Test(arguments: [
        ("Продолжать?", true), ("Что скажешь? **", true), ("Сделано.", false), ("", false),
        ("Вопрос? Нет, всё готово.", false),
    ])
    func questionHeuristic(text: String, expected: Bool) {
        #expect(SessionStatus.looksLikeQuestion(text) == expected)
    }
}

@Suite struct EventLogTests {
    @Test func appendReplayCompact() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<5 { try EventLog.append(event("UserPromptSubmit"), dir: dir) }
        try EventLog.append(event("Stop", ["last_assistant_message": "ok"]), dir: dir)
        #expect(EventLog.read(sessionID: "s1", dir: dir).count == 6)
        #expect(EventLog.replay(sessionID: "s1", dir: dir)?.activity == .idle)
        EventLog.compact(sessionID: "s1", maxLines: 2, dir: dir)
        #expect(EventLog.read(sessionID: "s1", dir: dir).count == 2)
        #expect(EventLog.replay(sessionID: "missing", dir: dir) == nil)
    }
}

@Suite struct SocketTests {
    @Test func deliversEventOverUnixSocket() async throws {
        let path = "/tmp/artel-test-\(UUID().uuidString.prefix(8)).sock"
        let received = AsyncStream<HookEvent>.makeStream()
        let server = HookServer(path: path) { received.continuation.yield($0) }
        try server.start()
        defer { server.stop() }
        let payload = try JSONEncoder.artel.encode(event("Stop", ["last_assistant_message": "hi"]))
        #expect(HookSocket.send(payload, to: path))
        var it = received.stream.makeAsyncIterator()
        let got = await it.next()
        #expect(got?.lastAssistantMessage == "hi")
        #expect(!HookSocket.send(payload, to: "/tmp/nobody-\(UUID().uuidString.prefix(6)).sock"))
    }
}

@Suite struct ClaudeCommand {
    let agent = ClaudeCodeAgent()

    @Test func newSession() {
        let spec = LaunchSpec(executable: "/bin/claude", name: "artel #1", model: "opus", permissionMode: "auto",
                              settingsFile: "/s.json", conversationID: "c1", resume: false, initialPrompt: "hello")
        #expect(agent.command(for: spec) == [
            "/bin/claude", "--settings", "/s.json", "--permission-mode", "auto", "--name", "artel #1",
            "--model", "opus", "--session-id", "c1", "hello",
        ])
    }

    @Test func resumeIgnoresPromptAndDefaultModel() {
        let spec = LaunchSpec(executable: "/bin/claude", name: "n", model: nil, permissionMode: "manual",
                              settingsFile: "/s.json", conversationID: "c1", resume: true, initialPrompt: "x")
        #expect(agent.command(for: spec) == [
            "/bin/claude", "--settings", "/s.json", "--permission-mode", "manual", "--name", "n", "--resume", "c1",
        ])
    }

    @Test func transcriptPathEncoding() {
        let url = ClaudeCodeAgent.transcriptURL(conversationID: "abc", cwd: "/Users/me/work/my.app")
        #expect(url.path.hasSuffix(".claude/projects/-Users-me-work-my-app/abc.jsonl"))
    }

    @Test func hookSettingsQuotePath() throws {
        let data = try ClaudeCodeAgent.hookSettings(hookBinary: "/Users/me/Library/Application Support/Artel/bin/artel-hook")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = obj["hooks"] as! [String: Any]
        #expect(hooks["Stop"] != nil && hooks["PermissionRequest"] != nil)
        let cmd = (((hooks["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
        #expect(cmd == "'/Users/me/Library/Application Support/Artel/bin/artel-hook'")
        #expect(obj["permissions"] == nil)  // no aide-mcp tools to pre-approve any more
    }

    @Test func tmuxArgsUseArgvForm() {
        let args = Tmux.newSessionArgs(name: "artel-x", cwd: "/p", env: ["B": "2", "A": "1"], command: ["claude", "a b"])
        #expect(args == ["new-session", "-d", "-s", "artel-x", "-c", "/p", "-x", "200", "-y", "50",
                         "-e", "A=1", "-e", "B=2", "--", "claude", "a b"])
    }

    @Test func tmuxConfigUsesCsiUExtendedKeys() {
        #expect(Tmux.config.contains("set -g extended-keys on"))
        #expect(Tmux.config.contains("set -g extended-keys-format csi-u"))
    }
}

@Suite struct ProjectChecks {
    @Test func descriptionDetection() {
        #expect(!ProjectValidator.hasDescription(ProjectValidator.claudeMDTemplate(projectName: "X")))
        #expect(ProjectValidator.hasDescription("# X\n\n## Описание\nПриложение для заметок."))
        #expect(!ProjectValidator.hasDescription("# X\n<!--\nмного\nстрок\n-->\n"))
        #expect(ProjectValidator.hasDescription("# X\n<!-- hint --> Реальный текст"))
    }

    @Test func detectsIssues() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectValidator.issues(at: dir) == [.notAGitRepository, .missingClaudeMD])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try ProjectValidator.claudeMDTemplate(projectName: "X").write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        #expect(ProjectValidator.issues(at: dir) == [.emptyClaudeMD])
        try "# X\nОписание".write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        #expect(ProjectValidator.issues(at: dir).isEmpty)
        #expect(ProjectValidator.issues(at: dir.appendingPathComponent("nope")) == [.notADirectory])
    }

    @Test func gitRepositoryIsDetectedLive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "p", path: dir.path)
        #expect(!project.isGitRepository)
        // A worktree or submodule has a `.git` file instead of a directory.
        try "gitdir: /elsewhere\n".write(to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(project.isGitRepository)
        #expect(!ProjectValidator.issues(at: dir).contains(.notAGitRepository))
    }
}

@Suite struct GridLayoutTests {
    @Test func fillsWhenFew() {
        let one = GridLayout.compute(count: 1, width: 1600, height: 900)
        #expect(one.rows == 1 && one.columns == 1 && one.cardWidth == 1600)
        let four = GridLayout.compute(count: 4, width: 1600, height: 900)
        #expect(four.rows == 2 && four.columns == 2)
        #expect(GridLayout.compute(count: 3, width: 1600, height: 900).rows == 1)
        let narrow = GridLayout.compute(count: 3, width: 1000, height: 900)
        #expect(narrow.rows == 2 && narrow.columns == 2)
    }

    @Test func scrollsWhenMany() {
        let ten = GridLayout.compute(count: 10, width: 1600, height: 900)
        #expect(ten.columns == 3 && ten.rows == 4)
        #expect(ten.cardWidth >= GridLayout.minCardWidth)
        #expect(ten.cardHeight == (900 - GridLayout.spacing) / 2)
        #expect(ten.rowsOf(Array(0..<5)) == [[0, 1, 2], [3, 4]])
        let tiny = GridLayout.compute(count: 6, width: 400, height: 300)
        #expect(tiny.columns == 1 && tiny.cardWidth == 400 && tiny.cardHeight == GridLayout.minCardHeight)
    }

    @Test func widerCardPushesFollowingSessionsWithoutChangingTheirOrder() {
        let layout = GridLayout.compute(spans: [GridSpan(columns: 2), GridSpan(), GridSpan()],
                                        width: 1600, height: 900)
        #expect(layout.columns == 3)
        #expect(layout.rows == 2)
        #expect(layout.placements.map(\.index) == [0, 1, 2])
        #expect(layout.placements[0].row == 0 && layout.placements[0].column == 0)
        #expect(layout.placements[0].span.columns == 2)
        #expect(layout.placements[1].row == 0 && layout.placements[1].column == 2)
        #expect(layout.placements[2].row == 1 && layout.placements[2].column == 0)
        #expect(layout.width(for: layout.placements[0]) == 2 * layout.cardWidth + GridLayout.spacing)
    }

    @Test func tallerCardOccupiesCellsInFollowingRows() {
        let layout = GridLayout.compute(spans: [GridSpan(rows: 2), GridSpan(), GridSpan(), GridSpan()],
                                        width: 1600, height: 900)
        #expect(layout.columns == 2)
        #expect(layout.rows == 3)
        #expect(layout.placements.map { [$0.row, $0.column] } == [[0, 0], [0, 1], [1, 1], [2, 0]])
        #expect(layout.height(for: layout.placements[0]) == 900)
        #expect(layout.contentHeight == 3 * layout.cardHeight + 2 * GridLayout.spacing)
    }

    @Test func clampsSpansToGridAndMinimumSize() {
        let layout = GridLayout.compute(spans: [GridSpan(columns: 10, rows: 0), GridSpan(columns: -2)],
                                        width: 1000, height: 900)
        #expect(layout.columns == 2)
        #expect(layout.placements[0].span == GridSpan(columns: 2, rows: 1))
        #expect(layout.placements[1].span == GridSpan())
        #expect(layout.placements[1].row == 1)
    }

    @Test func sessionSpansPersistAndDefaultToOneCell() throws {
        let record = SessionRecord(name: "Test", projectID: UUID(), cwd: "/tmp", model: nil,
                                   permissionMode: "auto", columnSpan: 2, rowSpan: 3)
        var state = AppState()
        state.sessions = [record]
        let decoded = try JSONDecoder.artel.decode(AppState.self, from: JSONEncoder.artel.encode(state))
        #expect(decoded.sessions[0].columnSpan == 2)
        #expect(decoded.sessions[0].rowSpan == 3)

        let legacy = try JSONDecoder.artel.decode(SessionRecord.self, from: Data(#"{"id":"s","name":"Test","projectID":"\#(record.projectID.uuidString)","cwd":"/tmp","permissionMode":"auto"}"#.utf8))
        #expect(legacy.columnSpan == 1 && legacy.rowSpan == 1)
    }

    @Test func persistedStateToleratesMissingKeys() throws {
        let state = try JSONDecoder.artel.decode(AppState.self, from: Data(#"{"settings":{"waitingFirst":true}}"#.utf8))
        #expect(state.settings.waitingFirst)
        #expect(state.settings.notifications.enabled)
        #expect(state.tabs.count == 1)
        #expect(state.lastSessionSettings == nil)
    }

    @Test func lastSessionSettingsRoundTrip() throws {
        var state = AppState()
        let settings = SessionLaunchSettings(projectID: UUID(), agentID: KimiCodeAgent.id,
                                             model: "kimi-code/k3", permissionMode: "auto")
        state.lastSessionSettings = settings
        let decoded = try JSONDecoder.artel.decode(AppState.self, from: JSONEncoder.artel.encode(state))
        #expect(decoded.lastSessionSettings == settings)
    }
}
