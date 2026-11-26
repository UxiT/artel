import Foundation
import Testing
@testable import ArtelCore

@Suite struct UsageParsing {
    @Test func parsesWindows() throws {
        let json = """
        {"five_hour":{"utilization":62.5,"resets_at":"2026-11-05T15:00:00.123Z"},
         "seven_day":{"utilization":31,"resets_at":"2026-11-10T00:00:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":140,"resets_at":null},
         "extra":{"x":1}}
        """
        let w = try ClaudeUsage.parseUsage(Data(json.utf8))
        #expect(w.map(\.id) == ["session", "weekly", "weekly-sonnet"])
        #expect(w[0].usedPercent == 62.5 && w[0].remainingPercent == 37.5)
        #expect(w[0].resetsAt != nil && w[1].resetsAt != nil)
        #expect(w[2].usedPercent == 100 && w[2].resetsAt == nil)  // clamped
        #expect(throws: (any Error).self) { try ClaudeUsage.parseUsage(Data("[]".utf8)) }
    }

    @Test func plan() {
        #expect(ClaudeUsage.parsePlan(Data(#"{"account":{"has_claude_max":true}}"#.utf8)) == "Max")
        #expect(ClaudeUsage.parsePlan(Data(#"{"account":{},"organization":{"organization_type":"claude_pro"}}"#.utf8)) == "Pro")
        #expect(ClaudeUsage.parsePlan(Data("{}".utf8)) == nil)
    }

    @Test func credentials() {
        let c = ClaudeUsage.parseCredentials(#"{"claudeAiOauth":{"accessToken":"t0k","subscriptionType":"max","expiresAt":1800000000000}}"#)
        #expect(c?.accessToken == "t0k" && c?.subscriptionType == "max")
        #expect(c?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ClaudeUsage.parseCredentials(#"{"other":{}}"#) == nil)
        #expect(ClaudeUsage.parseCredentials("garbage") == nil)
    }

    @Test func requestHeaders() {
        let r = ClaudeUsage.request(ClaudeUsage.usageURL, token: "abc")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }
}

@Suite struct KimiUsageParsing {
    @Test func parsesWindows() throws {
        let json = """
        {"usages":{
         "limit_5h":{"used_ratio":0.625,"reset_time":"2026-11-05T15:00:00.123Z"},
         "limit_7d":{"used_ratio":"0.31","reset_time":"2026-11-10T00:00:00Z"},
         "limit_month_total":{"used_ratio":1.4,"reset_time":null},
         "limit_month_code":{"used_ratio":0.2}
        },"boosterWallet":null}
        """
        let w = try KimiUsage.parseUsage(Data(json.utf8))
        #expect(w.map(\.id) == ["session", "weekly", "monthly"])
        #expect(w[0].usedPercent == 62.5 && w[1].usedPercent == 31)
        #expect(w[0].resetsAt != nil && w[1].resetsAt != nil)
        #expect(w[2].usedPercent == 100 && w[2].resetsAt == nil)
        #expect(throws: (any Error).self) { try KimiUsage.parseUsage(Data("[]".utf8)) }
    }

    @Test func credentialsAndRequest() {
        let c = KimiUsage.parseCredentials(#"{"access_token":"t0k","refresh_token":"secret","expires_at":1800000000}"#)
        #expect(c?.accessToken == "t0k")
        #expect(KimiUsage.parseCredentials(#"{"other":{}}"#) == nil)
        let r = KimiUsage.request(KimiUsage.usageURL(baseURL: KimiUsage.defaultBaseURL), token: "abc")
        #expect(r.url?.absoluteString == "https://api.kimi.com/coding/v1/usages")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func parsesManagedProviderConfiguration() {
        let config = """
        [providers."managed:kimi-code"]
        type = "kimi"
        baseUrl = "https://api.kimi.ai/coding/v1"
        [providers."managed:kimi-code".oauth]
        key = "oauth/kimi-code-env-0123456789abcdef"
        """
        let parsed = KimiUsage.parseConfiguration(config)
        #expect(parsed.baseURL.absoluteString == "https://api.kimi.ai/coding/v1")
        #expect(parsed.credentialKey == "kimi-code-env-0123456789abcdef")
        let overridden = KimiUsage.parseConfiguration(config, environment: [
            "KIMI_CODE_BASE_URL": "https://example.test/custom/v1",
        ])
        #expect(overridden.baseURL.absoluteString == "https://example.test/custom/v1")
        #expect(KimiUsage.usageURL(baseURL: overridden.baseURL).absoluteString == "https://example.test/custom/v1/usages")
    }

    @Test func readsOnlyTheConfiguredCredentialFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("artel-kimi-usage-\(UUID().uuidString)")
        let credentials = home.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = """
        [providers."managed:kimi-code"]
        baseUrl = "https://api.kimi.ai/coding/v1"
        [providers."managed:kimi-code".oauth]
        key = "oauth/kimi-code"
        """
        try config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try #"{"access_token":"fake-test-token"}"#.write(
            to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
        let login = KimiUsage.readCredentials(environment: ["KIMI_CODE_HOME": home.path])
        #expect(login?.0.accessToken == "fake-test-token")
        #expect(login?.1.baseURL.host() == "api.kimi.ai")
    }
}

@Suite struct LimitVisibilitySettings {
    @Test func legacySettingsShowBothAgents() throws {
        let settings = try JSONDecoder.artel.decode(LimitSettings.self, from: Data("{}".utf8))
        #expect(settings.shows(ClaudeCodeAgent.id))
        #expect(settings.shows(KimiCodeAgent.id))
    }

    @Test func visibilityRoundTrip() throws {
        var settings = LimitSettings()
        settings.setVisible(KimiCodeAgent.id, false)
        let decoded = try JSONDecoder.artel.decode(LimitSettings.self, from: JSONEncoder.artel.encode(settings))
        #expect(decoded.shows(ClaudeCodeAgent.id))
        #expect(!decoded.shows(KimiCodeAgent.id))
        #expect(LimitAlerts.key(LimitWindow(id: "session", label: "", shortLabel: "", usedPercent: 0, resetsAt: nil), agentID: "claude")
            != LimitAlerts.key(LimitWindow(id: "session", label: "", shortLabel: "", usedPercent: 0, resetsAt: nil), agentID: "kimi"))
    }
}

@Suite struct UsageAlerts {
    let reset = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func alertsOncePerPeriod() {
        let w = LimitWindow(id: "session", label: "", shortLabel: "", usedPercent: 90, resetsAt: reset)
        let due = LimitAlerts.due([w], thresholdRemaining: 15, alreadyAlerted: [])
        #expect(due.count == 1)
        let alerted: Set = [LimitAlerts.key(w)]
        #expect(LimitAlerts.due([w], thresholdRemaining: 15, alreadyAlerted: alerted).isEmpty)
        var next = w
        next.resetsAt = reset.addingTimeInterval(5 * 3600)  // new period → alert again
        #expect(LimitAlerts.due([next], thresholdRemaining: 15, alreadyAlerted: alerted).count == 1)
        var fine = w
        fine.usedPercent = 50
        #expect(LimitAlerts.due([fine], thresholdRemaining: 15, alreadyAlerted: []).isEmpty)
    }

    @Test func backoff() {
        #expect(Backoff.delay(failures: 1) == 60)
        #expect(Backoff.delay(failures: 3) == 240)
        #expect(Backoff.delay(failures: 20) == 1800)
        #expect(Backoff.delay(failures: 1, retryAfter: 600) == 600)
    }

    @Test func durations() {
        #expect(formatDuration(59) == "0m")
        #expect(formatDuration(2 * 3600 + 10 * 60) == "2h 10m")
        #expect(formatDuration(3 * 86400 + 5 * 3600) == "3d 5h")
    }
}

@Suite struct Templates {
    @Test func valuesAndBlocks() {
        let t = "A {{x}} B\n{{#y}}Y={{y}}{{/y}}\n\n\n\n{{#z}}Z{{/z}}C {{unknown}}."
        #expect(PromptTemplate.render(t, ["x": "1", "y": "2"]) == "A 1 B\nY=2\n\nC .")
        #expect(PromptTemplate.render(t, ["x": "1"]) == "A 1 B\n\nC .")
        #expect(PromptTemplate.render("{{#a}}open", ["a": "1"]) == "open")  // unbalanced tag dropped
        #expect(PromptTemplate.render("{{ x }} {{", ["x": "v"]) == "v {{")
    }

    @Test func customFrameUsedByBuild() {
        let project = Project(name: "p", path: "/p")
        let task = ArtelTask(projectID: project.id, directory: URL(fileURLWithPath: "/p/.artel/tasks/A-1"),
                            taskID: "A-1", title: "T", body: "do it")
        let out = TaskPrompt.build(task: task, project: project, worktree: nil,
                                   frame: "[{{task_id}}] {{#worktree}}WT{{/worktree}}{{project}}\n{{task_body}}")
        #expect(out == "[A-1] p\ndo it")
        // Default frame without a worktree drops the worktree sentence entirely.
        let def = TaskPrompt.build(task: task, project: project, worktree: nil)
        #expect(!def.contains("working directory") && def.hasSuffix("do it"))
    }
}

@Suite struct AgentAvailability {
    @Test func allEnabledByDefault() throws {
        let settings = try JSONDecoder.artel.decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.enabledAgentIDs == [ClaudeCodeAgent.id, KimiCodeAgent.id])
        #expect(settings.effectiveDefaultAgentID == ClaudeCodeAgent.id)
    }

    @Test func disablingDefaultFallsBack() throws {
        var settings = AppSettings()
        settings.setAgentEnabled(ClaudeCodeAgent.id, false)
        #expect(!settings.isAgentEnabled(ClaudeCodeAgent.id))
        #expect(settings.effectiveDefaultAgentID == KimiCodeAgent.id)
        let decoded = try JSONDecoder.artel.decode(AppSettings.self, from: JSONEncoder.artel.encode(settings))
        #expect(decoded.enabledAgentIDs == [KimiCodeAgent.id])
    }

    @Test func lastAgentStaysEnabled() {
        var settings = AppSettings()
        settings.setAgentEnabled(KimiCodeAgent.id, false)
        settings.setAgentEnabled(ClaudeCodeAgent.id, false)
        #expect(settings.enabledAgentIDs == [ClaudeCodeAgent.id])
        settings.disabledAgents = [ClaudeCodeAgent.id, KimiCodeAgent.id]  // hand-edited state.json
        #expect(settings.enabledAgentIDs == [ClaudeCodeAgent.id])
    }
}

@Suite struct FontSettingsTests {
    @Test func defaultsWhenMissing() throws {
        let settings = try JSONDecoder.artel.decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.fonts == FontSettings())
        #expect(settings.fonts.terminal.size == 12 && settings.fonts.terminal.family == nil)
    }

    @Test func roundTripAndClamp() throws {
        var settings = AppSettings()
        settings.fonts.editor = FontChoice(family: "Avenir Next", size: 15)
        let decoded = try JSONDecoder.artel.decode(AppSettings.self, from: JSONEncoder.artel.encode(settings))
        #expect(decoded.fonts.editor == FontChoice(family: "Avenir Next", size: 15))
        let huge = try JSONDecoder.artel.decode(FontChoice.self, from: Data(#"{"size": 400}"#.utf8))
        #expect(huge.size == FontChoice.sizeRange.upperBound)
    }
}
