import Foundation

/// One subscription limit window (5-hour session, weekly…).
public struct LimitWindow: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var shortLabel: String
    /// 0…100
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(id: String, label: String, shortLabel: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.shortLabel = shortLabel
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var subscriptionType: String?
    public var expiresAt: Date?
}

/// Claude subscription usage, the way the Claude Code CLI reads it (see docs/SPEC.md §4.7).
/// The endpoints are not a public API; everything that may change lives here.
public enum ClaudeUsage {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let keychainService = "Claude Code-credentials"

    static let buckets: [(key: String, id: String, label: String, short: String)] = [
        ("five_hour", "session", "5 hours", "5h"),
        ("seven_day", "weekly", "Week · all models", "7d"),
        ("seven_day_opus", "weekly-opus", "Week · Opus", "Opus"),
        ("seven_day_sonnet", "weekly-sonnet", "Week · Sonnet", "Sonnet"),
    ]

    public static func parseUsage(_ data: Data) throws -> [LimitWindow] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return buckets.compactMap { b in
            guard let bucket = json[b.key] as? [String: Any], let used = (bucket["utilization"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return LimitWindow(id: b.id, label: b.label, shortLabel: b.short, usedPercent: min(100, max(0, used)),
                               resetsAt: (bucket["resets_at"] as? String).flatMap(parseDate))
        }
    }

    public static func parsePlan(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = json["account"] as? [String: Any] ?? [:]
        if account["has_claude_max"] as? Bool == true { return "Max" }
        if account["has_claude_pro"] as? Bool == true { return "Pro" }
        return planName((json["organization"] as? [String: Any])?["organization_type"] as? String)
    }

    public static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let map = ["max": "Max", "claude_max": "Max", "pro": "Pro", "claude_pro": "Pro", "team": "Team",
                   "enterprise": "Enterprise", "free": "Free"]
        return map[raw.lowercased()] ?? raw
    }

    public static func parseCredentials(_ text: String) -> ClaudeCredentials? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = json["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (o["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredentials(accessToken: token, subscriptionType: o["subscriptionType"] as? String, expiresAt: expires)
    }

    /// Reads the Claude Code CLI login — read-only, never refreshed or written by Artel.
    /// macOS asks once for Keychain access; the file is the non-Keychain fallback.
    public static func readCredentials(environment: [String: String]) -> ClaudeCredentials? {
        if let r = try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: 60),
           r.ok, let creds = parseCredentials(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return creds
        }
        let configDir = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        if let text = try? String(contentsOf: configDir.appendingPathComponent(".credentials.json"), encoding: .utf8) {
            return parseCredentials(text)
        }
        return nil
    }

    public static func request(_ url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Artel/0.3", forHTTPHeaderField: "User-Agent")
        return r
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public struct KimiCredentials: Equatable, Sendable {
    public var accessToken: String
}

public struct KimiConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var credentialKey: String
}

/// Kimi Code subscription usage, matching the CLI's `/usage` request.
/// The endpoints are not a public API; everything that may change lives here.
public enum KimiUsage {
    public static let defaultBaseURL = URL(string: "https://api.kimi.com/coding/v1")!

    static let buckets: [(key: String, id: String, label: String, short: String)] = [
        ("limit_5h", "session", "5 hours", "5h"),
        ("limit_7d", "weekly", "Week", "7d"),
        ("limit_month_total", "monthly", "Month · total", "Mo"),
    ]

    public static func usageURL(baseURL: URL) -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/usages")!
    }

    public static func parseUsage(_ data: Data) throws -> [LimitWindow] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let usages = json["usages"] as? [String: Any] ?? [:]
        return buckets.compactMap { b in
            guard let bucket = usages[b.key] as? [String: Any],
                  let ratio = number(bucket["used_ratio"]) else { return nil }
            return LimitWindow(id: b.id, label: b.label, shortLabel: b.short,
                               usedPercent: min(100, max(0, ratio * 100)),
                               resetsAt: (bucket["reset_time"] as? String).flatMap(ClaudeUsage.parseDate))
        }
    }

    public static func parseCredentials(_ text: String) -> KimiCredentials? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else { return nil }
        return KimiCredentials(accessToken: token)
    }

    public static func parseConfiguration(_ text: String, environment: [String: String] = [:]) -> KimiConfiguration {
        var baseURL = defaultBaseURL
        var credentialKey = "kimi-code"
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let assignment = tomlAssignment(line) else { continue }
            if section == "providers.\"managed:kimi-code\"", assignment.key == "baseUrl",
               let url = URL(string: assignment.value) {
                baseURL = url
            }
            if section == "providers.\"managed:kimi-code\".oauth", assignment.key == "key" {
                credentialKey = assignment.value.hasPrefix("oauth/") ? String(assignment.value.dropFirst(6)) : assignment.value
            }
        }
        if let override = environment["KIMI_CODE_BASE_URL"], !override.isEmpty,
           let url = URL(string: override) {
            baseURL = url
        }
        return KimiConfiguration(baseURL: baseURL, credentialKey: credentialKey)
    }

    /// Reads the Kimi Code CLI login and configuration — read-only, never refreshed or written by Artel.
    public static func readCredentials(environment: [String: String]) -> (KimiCredentials, KimiConfiguration)? {
        let home = environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
        let configText = (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let configuration = parseConfiguration(configText, environment: environment)
        let directory = home.appendingPathComponent("credentials", isDirectory: true)
        if !configuration.credentialKey.isEmpty, !configuration.credentialKey.contains("/"),
           !configuration.credentialKey.hasPrefix("."),
           let text = try? String(contentsOf: directory.appendingPathComponent("\(configuration.credentialKey).json"), encoding: .utf8),
           let credentials = parseCredentials(text) {
            return (credentials, configuration)
        }
        // Older/hand-written global configurations may not persist the derived OAuth key.
        let scoped = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("kimi-code-env-") && $0.hasSuffix(".json") } ?? []
        if scoped.count == 1,
           let text = try? String(contentsOf: directory.appendingPathComponent(scoped[0]), encoding: .utf8),
           let credentials = parseCredentials(text) {
            return (credentials, configuration)
        }
        return nil
    }

    public static func request(_ url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Artel/0.3", forHTTPHeaderField: "User-Agent")
        return r
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func tomlAssignment(_ line: String) -> (key: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
        value = String(value.dropFirst().dropLast())
        value = value.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return (key, value)
    }
}

/// "Less than N % left" alerts: one per window until it resets.
public enum LimitAlerts {
    /// Key identifying a window *period*, so the alert re-arms after the reset.
    public static func key(_ w: LimitWindow, agentID: String? = nil) -> String {
        "\(agentID.map { "\($0):" } ?? "")\(w.id)@\(w.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }

    public static func due(_ windows: [LimitWindow], thresholdRemaining: Double, alreadyAlerted: Set<String>) -> [LimitWindow] {
        windows.filter { $0.remainingPercent < thresholdRemaining && !alreadyAlerted.contains(key($0)) }
    }
}

/// Retry delay after failures: 1, 2, 4… minutes, capped at 30, honouring Retry-After.
public enum Backoff {
    public static func delay(failures: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let exp = min(30.0 * 60, 60.0 * pow(2, Double(max(0, failures - 1))))
        return max(exp, retryAfter ?? 0)
    }
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
