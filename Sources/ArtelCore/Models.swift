import Foundation

public struct Project: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var colorIndex: Int
    /// `claude --permission-mode` for sessions of this project.
    public var permissionMode: String
    /// Model alias or id; nil = ask / agent default.
    public var defaultModel: String?
    /// Prefix for task ids (`ARTEL-12`).
    public var taskPrefix: String
    /// Branch task worktrees start from (and the diff is taken against); nil = the main checkout's current branch.
    public var baseBranch: String?
    /// Commit `.artel/` (default) or keep it in `.gitignore`.
    public var storeArtelInGit: Bool
    /// Code editor for this project (path to the .app); nil = not chosen yet.
    public var editorPath: String?

    public init(id: UUID = UUID(), name: String, path: String, colorIndex: Int = 0,
                permissionMode: String = "auto", defaultModel: String? = nil, taskPrefix: String = "ARTEL",
                baseBranch: String? = nil, storeArtelInGit: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.colorIndex = colorIndex
        self.permissionMode = permissionMode
        self.defaultModel = defaultModel
        self.taskPrefix = taskPrefix
        self.baseBranch = baseBranch
        self.storeArtelInGit = storeArtelInGit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "auto"
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        taskPrefix = try c.decodeIfPresent(String.self, forKey: .taskPrefix) ?? "ARTEL"
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        storeArtelInGit = try c.decodeIfPresent(Bool.self, forKey: .storeArtelInGit) ?? true
        editorPath = try c.decodeIfPresent(String.self, forKey: .editorPath)
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// A slot in the workspace: one agent process living in Artel's tmux server.
public struct SessionRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Short id; also the tmux session name suffix and `ARTEL_SESSION_ID`.
    public var id: String
    public var name: String
    public var projectID: UUID
    public var cwd: String
    public var agentID: String
    public var model: String?
    public var permissionMode: String
    public var createdAt: Date
    /// Workspace tab the card lives in.
    public var tabID: UUID?
    /// Number of grid cells occupied by the card.
    public var columnSpan: Int
    public var rowSpan: Int
    /// The agent process exited on its own (e.g. `/exit`); don't restart it automatically.
    public var exited: Bool
    /// Agent conversation id (Claude session id) used for `--resume`; updated from hook events.
    public var conversationID: String?
    /// Task this session works on (task id inside `projectID`), if any.
    public var taskID: String?

    public init(id: String = SessionRecord.newID(), name: String, projectID: UUID, cwd: String,
                agentID: String = ClaudeCodeAgent.id, model: String?, permissionMode: String,
                createdAt: Date = Date(), tabID: UUID? = nil, columnSpan: Int = 1, rowSpan: Int = 1,
                exited: Bool = false, conversationID: String? = nil) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.cwd = cwd
        self.agentID = agentID
        self.model = model
        self.permissionMode = permissionMode
        self.createdAt = createdAt
        self.tabID = tabID
        self.columnSpan = max(1, columnSpan)
        self.rowSpan = max(1, rowSpan)
        self.exited = exited
        self.conversationID = conversationID
    }

    public var tmuxName: String { Tmux.sessionPrefix + id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        cwd = try c.decode(String.self, forKey: .cwd)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ClaudeCodeAgent.id
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "auto"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        tabID = try c.decodeIfPresent(UUID.self, forKey: .tabID)
        columnSpan = max(1, try c.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1)
        rowSpan = max(1, try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1)
        exited = try c.decodeIfPresent(Bool.self, forKey: .exited) ?? false
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

public struct WorkspaceTab: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

public struct NotificationSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var waitingInput = true
    public var waitingPermission = true
    public var finished = true
    public var error = true
    /// Notify even when Artel is the frontmost app.
    public var whenActive = false
    public var sound = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        waitingInput = try c.decodeIfPresent(Bool.self, forKey: .waitingInput) ?? d.waitingInput
        waitingPermission = try c.decodeIfPresent(Bool.self, forKey: .waitingPermission) ?? d.waitingPermission
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? d.finished
        error = try c.decodeIfPresent(Bool.self, forKey: .error) ?? d.error
        whenActive = try c.decodeIfPresent(Bool.self, forKey: .whenActive) ?? d.whenActive
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
    }

    public func allows(_ activity: SessionActivity) -> Bool {
        guard enabled else { return false }
        switch activity {
        case .waitingInput: return waitingInput
        case .waitingPermission: return waitingPermission
        case .idle: return finished
        case .error: return error
        default: return false
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Explicit paths; nil = auto-detect.
    public var claudePath: String?
    public var kimiPath: String?
    public var tmuxPath: String?
    /// Use the tmux shipped inside Artel even when a system tmux exists.
    public var preferBundledTmux = false
    /// Agent for new sessions and tasks; nil = Claude Code.
    public var defaultAgentID: String?
    /// Agents turned off in settings: not offered for new sessions/tasks, their limits are hidden.
    /// Stored as the disabled set so newly added agents are on by default.
    public var disabledAgents: Set<String> = []
    /// Default model per agent id (LaunchSpec model values, e.g. "opus" / "kimi-code/k3").
    public var defaultModels: [String: String] = [:]
    public var notifications = NotificationSettings()
    /// Move sessions that need the operator to the front of the grid.
    public var waitingFirst = false
    public var limits = LimitSettings()
    /// Fonts of the text areas (terminal, editor, preview, code).
    public var fonts = FontSettings()
    /// Body of a new task; nil = built-in template.
    public var taskTemplate: String?
    /// Frame of the agent's first prompt (PromptTemplate syntax); nil = built-in.
    public var promptFrame: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        kimiPath = try c.decodeIfPresent(String.self, forKey: .kimiPath)
        tmuxPath = try c.decodeIfPresent(String.self, forKey: .tmuxPath)
        preferBundledTmux = try c.decodeIfPresent(Bool.self, forKey: .preferBundledTmux) ?? false
        defaultAgentID = try c.decodeIfPresent(String.self, forKey: .defaultAgentID)
        disabledAgents = try c.decodeIfPresent(Set<String>.self, forKey: .disabledAgents) ?? []
        defaultModels = try c.decodeIfPresent([String: String].self, forKey: .defaultModels) ?? [:]
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        waitingFirst = try c.decodeIfPresent(Bool.self, forKey: .waitingFirst) ?? false
        limits = try c.decodeIfPresent(LimitSettings.self, forKey: .limits) ?? LimitSettings()
        fonts = try c.decodeIfPresent(FontSettings.self, forKey: .fonts) ?? FontSettings()
        taskTemplate = try c.decodeIfPresent(String.self, forKey: .taskTemplate)
        promptFrame = try c.decodeIfPresent(String.self, forKey: .promptFrame)
        // A frame written for the removed plan/review workflow refers to aide-mcp tools: fall back to the built-in one.
        if let frame = promptFrame, PromptTemplate.isObsolete(frame) { promptFrame = nil }
        // Migration: the old single defaultModel always belonged to Claude Code.
        if defaultModels.isEmpty, let legacy = try c.decodeIfPresent(String.self, forKey: .defaultModel) {
            defaultModels[ClaudeCodeAgent.id] = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(claudePath, forKey: .claudePath)
        try c.encodeIfPresent(kimiPath, forKey: .kimiPath)
        try c.encodeIfPresent(tmuxPath, forKey: .tmuxPath)
        try c.encode(preferBundledTmux, forKey: .preferBundledTmux)
        try c.encodeIfPresent(defaultAgentID, forKey: .defaultAgentID)
        try c.encode(disabledAgents, forKey: .disabledAgents)
        try c.encode(defaultModels, forKey: .defaultModels)
        try c.encode(notifications, forKey: .notifications)
        try c.encode(waitingFirst, forKey: .waitingFirst)
        try c.encode(limits, forKey: .limits)
        try c.encode(fonts, forKey: .fonts)
        try c.encodeIfPresent(taskTemplate, forKey: .taskTemplate)
        try c.encodeIfPresent(promptFrame, forKey: .promptFrame)
    }

    enum CodingKeys: String, CodingKey {
        case claudePath, kimiPath, tmuxPath, preferBundledTmux, defaultAgentID, disabledAgents, defaultModels
        case notifications, waitingFirst, limits, fonts, taskTemplate, promptFrame
        /// Legacy single model field (Claude Code); migrated into `defaultModels` on decode.
        case defaultModel
    }

    public func isAgentEnabled(_ agentID: String) -> Bool {
        enabledAgentIDs.contains(agentID)
    }

    /// Enabled agents in registry order; never empty (all disabled = the first one stays usable).
    public var enabledAgentIDs: [String] {
        let ids = CodingAgents.all.map(\.agentID).filter { !disabledAgents.contains($0) }
        return ids.isEmpty ? [ClaudeCodeAgent.id] : ids
    }

    /// The agent for new sessions and tasks: the chosen default if it is enabled, else the first enabled one.
    public var effectiveDefaultAgentID: String {
        let chosen = defaultAgentID ?? ClaudeCodeAgent.id
        return enabledAgentIDs.contains(chosen) ? chosen : enabledAgentIDs[0]
    }

    /// Turns an agent on or off; the last enabled agent cannot be turned off.
    public mutating func setAgentEnabled(_ agentID: String, _ enabled: Bool) {
        if enabled {
            disabledAgents.remove(agentID)
        } else if enabledAgentIDs.contains(where: { $0 != agentID }) {
            disabledAgents.insert(agentID)
        }
    }

    /// The default model for an agent (nil = the agent's own default / ask at launch).
    public func defaultModel(for agentID: String?) -> String? {
        defaultModels[agentID ?? ClaudeCodeAgent.id]
    }
}

/// Subscription limits bar (docs/SPEC.md §4.7).
/// A font for one kind of text area: family name (nil = system font) and size in points.
public struct FontChoice: Codable, Equatable, Sendable {
    public static let sizeRange: ClosedRange<Double> = 8...32

    public var family: String?
    public var size: Double

    public init(family: String? = nil, size: Double) {
        self.family = family
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        let size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 13
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    enum CodingKeys: String, CodingKey { case family, size }
}

/// Fonts of every kind of text area in the app.
public struct FontSettings: Codable, Equatable, Sendable {
    public static let defaults = FontSettings()

    /// Session terminals and installer terminals (monospaced).
    public var terminal = FontChoice(size: 12)
    /// Markdown source: task text, prompts, project docs, templates.
    public var editor = FontChoice(size: 13)
    /// Rendered markdown.
    public var preview = FontChoice(size: 13)
    /// Code and file contents: diffs, file viewer, code inside the editor (monospaced).
    public var code = FontChoice(size: 12)

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FontSettings.defaults
        terminal = try c.decodeIfPresent(FontChoice.self, forKey: .terminal) ?? d.terminal
        editor = try c.decodeIfPresent(FontChoice.self, forKey: .editor) ?? d.editor
        preview = try c.decodeIfPresent(FontChoice.self, forKey: .preview) ?? d.preview
        code = try c.decodeIfPresent(FontChoice.self, forKey: .code) ?? d.code
    }

    enum CodingKeys: String, CodingKey { case terminal, editor, preview, code }
}

public struct LimitSettings: Codable, Equatable, Sendable {
    public static let defaultVisibleAgents: Set<String> = [ClaudeCodeAgent.id, KimiCodeAgent.id]

    public var enabled = true
    public var intervalMinutes = 1
    public var alerts = true
    /// Alert when less than this share of a window is left.
    public var thresholdRemaining = 15
    /// Agents whose limits appear in the shared status-bar segment.
    public var visibleAgents = defaultVisibleAgents

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 1
        alerts = try c.decodeIfPresent(Bool.self, forKey: .alerts) ?? true
        thresholdRemaining = try c.decodeIfPresent(Int.self, forKey: .thresholdRemaining) ?? 15
        visibleAgents = try c.decodeIfPresent(Set<String>.self, forKey: .visibleAgents) ?? Self.defaultVisibleAgents
    }

    public func shows(_ agentID: String) -> Bool {
        visibleAgents.contains(agentID)
    }

    public mutating func setVisible(_ agentID: String, _ visible: Bool) {
        if visible {
            visibleAgents.insert(agentID)
        } else {
            visibleAgents.remove(agentID)
        }
    }
}

/// Settings reused when the operator quickly opens another session.
public struct SessionLaunchSettings: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var agentID: String
    public var model: String?
    public var permissionMode: String

    public init(projectID: UUID, agentID: String, model: String?, permissionMode: String) {
        self.projectID = projectID
        self.agentID = agentID
        self.model = model
        self.permissionMode = permissionMode
    }

    public init(_ record: SessionRecord) {
        self.init(projectID: record.projectID, agentID: record.agentID,
                  model: record.model, permissionMode: record.permissionMode)
    }
}

/// Everything Artel persists in `state.json`.
public struct AppState: Codable, Equatable, Sendable {
    public var projects: [Project] = []
    public var sessions: [SessionRecord] = []
    public var tabs: [WorkspaceTab] = [WorkspaceTab(title: "Сессии")]
    public var selectedTabID: UUID?
    public var expandedSessionID: String?
    public var lastSessionSettings: SessionLaunchSettings?
    public var settings = AppSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so older state files keep loading as the app grows.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try c.decodeIfPresent([SessionRecord].self, forKey: .sessions) ?? []
        tabs = try c.decodeIfPresent([WorkspaceTab].self, forKey: .tabs) ?? [WorkspaceTab(title: "Сессии")]
        if tabs.isEmpty { tabs = [WorkspaceTab(title: "Сессии")] }
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        expandedSessionID = try c.decodeIfPresent(String.self, forKey: .expandedSessionID)
        lastSessionSettings = try c.decodeIfPresent(SessionLaunchSettings.self, forKey: .lastSessionSettings)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    public static func load(from url: URL = AppPaths.stateFile) -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        do {
            return try JSONDecoder.artel.decode(AppState.self, from: data)
        } catch {
            // Never silently overwrite an unreadable state file: keep a copy next to it.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return AppState()
        }
    }

    public func save(to url: URL = AppPaths.stateFile) throws {
        let enc = JSONEncoder.artel
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
