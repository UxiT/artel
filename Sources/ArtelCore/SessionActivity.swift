import Foundation

/// What an agent session is doing right now, derived from hook events.
public enum SessionActivity: String, Codable, Sendable, CaseIterable {
    /// Process is starting; no hook event yet.
    case starting
    /// Agent is processing a prompt or running tools.
    case working
    /// Agent asked the operator something and waits for an answer.
    case waitingInput
    /// Agent waits for a permission decision.
    case waitingPermission
    /// Agent started (or context was cleared) and waits for the first prompt.
    case ready
    /// Agent finished its turn; nothing is running.
    case idle
    /// The turn ended with an API error.
    case error
    /// The agent process has exited.
    case exited

    /// States where the operator is expected to act.
    public var needsAttention: Bool {
        self == .waitingInput || self == .waitingPermission || self == .error
    }

    public var title: String {
        switch self {
        case .starting: "starting"
        case .working: "working"
        case .waitingInput: "waiting for input"
        case .waitingPermission: "waiting for permission"
        case .ready: "ready"
        case .idle: "finished"
        case .error: "error"
        case .exited: "stopped"
        }
    }
}

/// Live state of one session, folded from its hook events.
public struct SessionStatus: Codable, Equatable, Sendable {
    public var activity: SessionActivity
    /// Since when the session is in `activity`.
    public var since: Date
    /// The question, permission request, error or last agent reply worth showing on the card.
    public var message: String?
    /// What the agent is doing right now (tool call), shown while working.
    public var detail: String?
    /// Latest Claude session id (changes after `/clear`); used for `--resume`.
    public var claudeSessionID: String?
    public var transcriptPath: String?

    public init(activity: SessionActivity = .starting, since: Date = Date(), message: String? = nil,
                detail: String? = nil, claudeSessionID: String? = nil, transcriptPath: String? = nil) {
        self.activity = activity
        self.since = since
        self.message = message
        self.detail = detail
        self.claudeSessionID = claudeSessionID
        self.transcriptPath = transcriptPath
    }

    /// Applies one hook event. Pure function: everything the UI shows about a session comes from here.
    public func applying(_ e: HookEvent) -> SessionStatus {
        var next = self
        // Kimi `/clear` starts the new conversation before ending the previous one.
        // The late SessionEnd must not stop the live process or restore the old conversation id.
        if e.name == "SessionEnd", let currentID = claudeSessionID,
           let endedID = e.claudeSessionID, currentID != endedID {
            return next
        }
        if let id = e.claudeSessionID { next.claudeSessionID = id }
        if let path = e.transcriptPath { next.transcriptPath = path }

        func set(_ activity: SessionActivity, message: String?? = .none, detail: String?? = .none) {
            if next.activity != activity { next.since = e.timestamp }
            next.activity = activity
            if case .some(let m) = message { next.message = m }
            if case .some(let d) = detail { next.detail = d }
        }

        switch e.name {
        case "SessionStart":
            // startup / resume / clear / compact: the agent is ready for input.
            if e.source == "compact" { break }
            set(.ready, message: .some(nil), detail: .some(nil))
        case "TurnStarted":
            // Kimi Code: a new turn began (user prompt, queued prompt, tool continuation).
            if next.activity != .working { set(.working, detail: .some(nil)) }
        case "UserPromptSubmit":
            set(.working, message: .some(e.prompt), detail: .some(nil))
        case "PreToolUse":
            if e.toolName == "AskUserQuestion" {
                set(.waitingInput, message: .some(e.toolSummary ?? "The agent asked a question"), detail: .some(nil))
            } else {
                set(.working, detail: .some(Self.toolLine(e)))
            }
        case "PostToolUse", "PostToolUseFailure":
            if next.activity == .waitingInput || next.activity == .waitingPermission {
                // The question was answered / permission decided: back to work, keep the prompt as context.
                set(.working, message: .some(nil), detail: .some(nil))
            } else {
                set(.working)
            }
        case "PermissionRequest":
            // AskUserQuestion also goes through the permission dialog: it is a question, not a permission.
            if e.toolName == "AskUserQuestion" { break }
            set(.waitingPermission, message: .some(Self.toolLine(e) ?? "Permission required"))
        case "Notification":
            // Claude Code: operator-facing notifications. Kimi Code only reports background tasks
            // here (task.completed and friends) — those never change the session status.
            guard e.clientType != "kimi_code_cli" else { break }
            switch e.notificationType {
            case "permission_prompt":
                // PermissionRequest usually came first with richer details; keep them.
                if next.activity != .waitingPermission && next.activity != .waitingInput {
                    set(.waitingPermission, message: .some(e.message ?? "Permission required"))
                }
            case "elicitation_dialog":
                set(.waitingInput, message: .some(e.message ?? "The agent is waiting for input"))
            default:
                // idle_prompt and others only repeat what Stop already told us.
                break
            }
        case "Stop":
            let reply = e.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let asks = reply.map(Self.looksLikeQuestion) ?? false
            set(asks ? .waitingInput : .idle, message: .some(reply), detail: .some(nil))
        case "StopFailure":
            set(.error, message: .some(e.message ?? e.lastAssistantMessage ?? "API error"), detail: .some(nil))
        case "Interrupt":
            // Kimi Code: the operator interrupted the turn (Esc); the agent waits for input again.
            set(.ready, message: .some(nil), detail: .some(nil))
        case "SessionEnd":
            // `clear` and `resume` are followed by a new SessionStart in the same process.
            if e.source != "clear" && e.source != "resume" {
                set(.exited, detail: .some(nil))
            }
        default:
            break
        }
        return next
    }

    static func toolLine(_ e: HookEvent) -> String? {
        guard let tool = e.toolName else { return nil }
        guard let summary = e.toolSummary else { return tool }
        return "\(tool): \(summary)"
    }

    /// The agent ended its turn with a question to the operator.
    static func looksLikeQuestion(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Look at the last non-empty line; trailing markdown/punctuation noise is ignored.
        let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        let trimmed = lastLine.trimmingCharacters(in: CharacterSet(charactersIn: " *_`)\"'»"))
        return trimmed.hasSuffix("?")
    }
}
