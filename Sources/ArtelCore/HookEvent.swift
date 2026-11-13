import Foundation

/// A Claude Code hook event, reduced to the fields Artel needs.
///
/// The hook binary builds it from the raw hook JSON (which can contain whole file
/// contents in `tool_input` / `tool_response`) so events stay small on disk and on the wire.
public struct HookEvent: Codable, Equatable, Sendable {
    public var artelSessionID: String
    public var timestamp: Date
    public var name: String
    public var claudeSessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var notificationType: String?
    public var message: String?
    public var toolName: String?
    /// Short human-readable summary of the tool call (command, file path, question…).
    public var toolSummary: String?
    public var prompt: String?
    public var lastAssistantMessage: String?
    /// `source` for SessionStart, `reason` for SessionEnd.
    public var source: String?
    /// Hook sender: "kimi_code_cli" for Kimi Code, absent for Claude Code.
    public var clientType: String?

    public init(
        artelSessionID: String, timestamp: Date = Date(), name: String,
        claudeSessionID: String? = nil, transcriptPath: String? = nil, cwd: String? = nil,
        notificationType: String? = nil, message: String? = nil, toolName: String? = nil,
        toolSummary: String? = nil, prompt: String? = nil, lastAssistantMessage: String? = nil,
        source: String? = nil, clientType: String? = nil
    ) {
        self.artelSessionID = artelSessionID
        self.timestamp = timestamp
        self.name = name
        self.claudeSessionID = claudeSessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.source = source
        self.clientType = clientType
    }

    /// Builds an event from the raw JSON a Claude Code or Kimi Code hook writes to the hook's stdin.
    public static func fromRawHookInput(_ data: Data, artelSessionID: String, now: Date = Date()) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["hook_event_name"] as? String else { return nil }
        let toolName = obj["tool_name"] as? String
        let toolInput = obj["tool_input"] as? [String: Any]
        return HookEvent(
            artelSessionID: artelSessionID,
            timestamp: now,
            name: name,
            claudeSessionID: obj["session_id"] as? String,
            transcriptPath: obj["transcript_path"] as? String,
            cwd: obj["cwd"] as? String,
            notificationType: obj["notification_type"] as? String,
            message: (obj["message"] as? String).map { truncate($0, 500) },
            toolName: toolName,
            toolSummary: toolName.flatMap { summarizeTool($0, input: toolInput) },
            prompt: (obj["prompt"] as? String).map { truncate($0, 500) },
            lastAssistantMessage: (obj["last_assistant_message"] as? String).map { truncate($0, 2000) },
            source: (obj["source"] as? String) ?? (obj["reason"] as? String),
            clientType: obj["client_type"] as? String
        )
    }

    static func summarizeTool(_ tool: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if tool == "AskUserQuestion" {
            // { questions: [{ question: "...", options: [...] }] }
            if let questions = input["questions"] as? [[String: Any]] {
                let texts = questions.compactMap { $0["question"] as? String }
                if !texts.isEmpty { return truncate(texts.joined(separator: "\n"), 500) }
            }
            if let q = input["question"] as? String { return truncate(q, 500) }
            return nil
        }
        for key in ["command", "file_path", "path", "pattern", "url", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return truncate(value.replacingOccurrences(of: "\n", with: " "), 200)
            }
        }
        return nil
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}

public extension JSONEncoder {
    static var artel: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

public extension JSONDecoder {
    static var artel: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy = LegacyAide.keyDecodingStrategy()
        return d
    }
}
