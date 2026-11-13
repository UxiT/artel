import ArtelCore
import AppKit
import Observation

/// Request to add a project that still needs fixing (git, CLAUDE.md).
struct PendingProject: Identifiable {
    let id = UUID()
    var url: URL
    var issues: [ProjectValidator.Issue]
    var claudeMD: String
}

struct NewSessionRequest: Identifiable {
    let id = UUID()
    var projectID: UUID?
}

struct InstallRequest: Identifiable {
    let id = UUID()
    var title: String
    var command: String
}

@MainActor
@Observable
final class AppModel {
    var state: AppState {
        didSet {
            scheduleSave()
            if AppFonts.shared.settings != state.settings.fonts {
                AppFonts.shared.settings = state.settings.fonts
                terminals.applyFont()
            }
            let old = usage.settings
            let new = state.settings.limits
            let oldAgents = usage.enabledAgents
            let newAgents = Set(state.settings.enabledAgentIDs)
            guard old != new || oldAgents != newAgents else { return }
            usage.settings = new
            usage.enabledAgents = newAgents
            if old.enabled != new.enabled || old.intervalMinutes != new.intervalMinutes
                || old.visibleAgents != new.visibleAgents || oldAgents != newAgents {
                usage.start()
            }
        }
    }
    /// Live status per session id.
    var statuses: [String: SessionStatus] = [:]

    // Environment & tools
    private(set) var loginEnvironment: [String: String] = ProcessInfo.processInfo.environment
    private(set) var claudePath: String?
    private(set) var claudeVersion: String?
    private(set) var kimiPath: String?
    private(set) var kimiVersion: String?
    private(set) var tmuxPath: String?
    private(set) var tmuxVersion: String?
    /// The tmux in use is the one shipped with Artel.
    private(set) var usingBundledTmux = false
    private(set) var brewPath: String?
    private(set) var isReady = false
    private(set) var isBootstrapping = true

    // UI state
    /// Top-level window section: sessions grid, task board, project docs.
    var section: AppSection = .sessions
    /// Projects section: selected project and document (relative path).
    var docsProjectID: UUID?
    var docsPath: String?
    /// Task shown in the task window (a separate, non-modal window).
    var openedTaskID: String?
    /// Archived session without a task shown in the same window.
    var openedNoTaskID: String?
    /// New task being written in the new-task sheet (not on disk yet).
    var newTaskDraft: TaskDraft?
    /// The new-task sheet is attached to the task window (⌘N pressed there) rather than to the main window.
    var newTaskInTaskWindow = false
    /// Windows, tracked for ⌘W and for choosing where launch / done / error dialogs appear.
    weak var mainWindow: NSWindow?
    weak var taskWindow: NSWindow?
    var keyWindowIsMain = true
    var keyWindowIsTask = false
    /// Launch / done / editor / error dialogs are shown on the task window. Frozen while one is on screen.
    var flowHostIsTask = false
    /// mtime of the open task's history.jsonl: aide-mcp / agents append to it outside the app.
    var openedHistoryModified: Date?
    /// Bumped by every "open task / archive": brings the task window forward even if it shows that item already.
    var taskWindowRequest = 0
    /// Bumped when a task's attachments/ folder changes from inside the app.
    var attachmentsVersion = 0
    /// Debug script: open the Settings window (needs the `openSettings` environment action of a view).
    var debugOpenSettings = 0
    /// Bumped on every history write, so open timelines reload.
    var historyVersion = 0
    var focusedSessionID: String?
    var isDraggingTask = false
    var pendingProject: PendingProject?
    var newSessionRequest: NewSessionRequest?
    var installRequest: InstallRequest?
    var projectSettingsID: UUID?
    var errorMessage: String?
    var sessionToStop: SessionRecord?
    var tabToClose: WorkspaceTab?

    // Tasks
    /// All tasks of all projects, as read from `.artel/tasks`.
    var tasks: [ArtelTask] = []
    var selectedTaskID: String?
    var taskFilter = TaskFilter()
    var taskLaunch: TaskLaunchRequest?
    var commitRequest: CommitRequest?
    /// Projects whose `.artel/` has uncommitted changes.
    var artelDirty: Set<UUID> = []
    /// Keyboard focus requests from menu commands (quick add, search).
    var focusRequest: FocusRequest?
    var taskFingerprints: [UUID: [String: Date]] = [:]
    var pendingTaskSaves: [String: Task<Void, Never>] = [:]
    /// Tasks with a launch in progress (worktree creation can take a moment).
    var launchingTasks: Set<String> = []
    /// Last version of each task read from / written to disk (base for 3-way merges with external edits).
    var taskBaselines: [String: ArtelTask] = [:]
    /// Temporary archives of sessions that were started without a task.
    var noTasks: [ArtelTask] = []
    var noTaskFingerprints: [UUID: [String: Date]] = [:]
    var editorRequest: EditorRequest?
    var doneRequest: DoneRequest?

    let agents = CodingAgents.all
    /// Agents enabled in settings: the only ones offered for new sessions and tasks.
    var enabledAgents: [any CodingAgent] {
        state.settings.enabledAgentIDs.map { CodingAgents.agent(forID: $0) }
    }
    let terminals = TerminalRegistry()
    let notifier = Notifier()
    let usage = UsageMonitor()
    private(set) var tmux: Tmux?
    private(set) var git: Git?
    var tmuxForTerminals: Tmux? { tmux }
    /// Bumped when a session's terminal must be recreated (new tmux client).
    var terminalEpoch: [String: Int] = [:]
    private var hookServer: HookServer?
    private var saveTask: Task<Void, Never>?

    /// The default agent (setting): its models and permission modes are offered in sheets.
    var agent: any CodingAgent { CodingAgents.agent(forID: state.settings.effectiveDefaultAgentID) }
    func agent(for record: SessionRecord) -> any CodingAgent { CodingAgents.agent(forID: record.agentID) }
    func agent(for task: ArtelTask) -> any CodingAgent { CodingAgents.agent(forID: task.agent) }

    /// Resolved executable for an agent id (detection or the explicit path override).
    func agentPath(for agentID: String?) -> String? {
        switch CodingAgents.agent(forID: agentID).agentID {
        case KimiCodeAgent.id: return kimiPath
        default: return claudePath
        }
    }

    /// Is this agent needed right now: the default one, or attached to some session.
    func needsAgent(_ agentID: String) -> Bool {
        state.settings.effectiveDefaultAgentID == agentID
            || state.sessions.contains { $0.agentID == agentID }
    }

    init() {
        LegacyMigration.run()
        try? AppPaths.ensureDirectories()
        state = AppState.load()
        if state.selectedTabID == nil || !state.tabs.contains(where: { $0.id == state.selectedTabID }) {
            state.selectedTabID = state.tabs.first?.id
        }
        terminals.model = self
        notifier.onOpen = { [weak self] id in self?.focus(id, activate: true) }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        isBootstrapping = true
        defer { isBootstrapping = false }
        let env = await Task.detached { Self.sessionEnvironment(ShellEnvironment.loadLoginEnvironment()) }.value
        loginEnvironment = env
        detectTools()
        do {
            try Tmux.writeConfig()
            try installHookBinary()
            try ClaudeCodeAgent.hookSettings(hookBinary: AppPaths.hookBinary.path).write(to: AppPaths.claudeSettings, options: .atomic)
            // Kimi Code reads hooks from its own config.toml; Artel keeps a marked block there.
            if kimiPath != nil { try KimiCodeAgent.installConfig(hookBinary: AppPaths.hookBinary.path) }
            if hookServer == nil {
                let server = HookServer { [weak self] event in
                    MainActor.assumeIsolated { self?.handle(event) }
                }
                try server.start()
                hookServer = server
            }
        } catch {
            errorMessage = "Не удалось подготовить окружение: \(error.localizedDescription)"
        }
        notifier.setUp()
        isReady = tmux != nil && agentPath(for: state.settings.effectiveDefaultAgentID) != nil
        if isReady { restoreSessions() }
        for record in state.sessions {
            let url = AppPaths.eventsFile(sessionID: record.id)
            logSizes[record.id] = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
        reloadAllTasks()
        for record in state.sessions where record.taskID == nil {
            archiveSession(record, captureTranscript: true)
        }
        startReconciling()
        usage.environment = loginEnvironment
        AppFonts.shared.settings = state.settings.fonts
        usage.settings = state.settings.limits
        usage.enabledAgents = Set(state.settings.enabledAgentIDs)
        usage.onAlert = { [weak self] agentID, w in self?.notifier.postLimit(agentID: agentID, w) }
        usage.start()
        updateBadge()
    }

    /// Environment for agents: the login environment minus variables that would confuse a nested agent.
    nonisolated static func sessionEnvironment(_ env: [String: String]) -> [String: String] {
        var env = env
        for key in ["TMUX", "TMUX_PANE", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                    ArtelEnv.sessionID, ArtelEnv.socket, ArtelEnv.eventsDir,
                    LegacyAide.sessionIDEnv, LegacyAide.socketEnv, LegacyAide.eventsDirEnv] {
            env.removeValue(forKey: key)
        }
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["COLORTERM"] = "truecolor"
        return env
    }

    func detectTools() {
        let path = loginEnvironment["PATH"]
        let fm = FileManager.default
        func resolve(_ override: String?, _ name: String) -> String? {
            if let override, !override.isEmpty { return fm.isExecutableFile(atPath: override) ? override : nil }
            return ShellEnvironment.which(name, path: path)
        }
        claudePath = resolve(state.settings.claudePath, "claude")
        kimiPath = resolve(state.settings.kimiPath, "kimi")
        let systemTmux = state.settings.preferBundledTmux ? nil : resolve(state.settings.tmuxPath, "tmux")
        if let systemTmux {
            tmuxPath = systemTmux
            usingBundledTmux = false
        } else if (try? installHelper("tmux", to: AppPaths.bundledTmux)) != nil,
                  fm.isExecutableFile(atPath: AppPaths.bundledTmux.path) {
            // No tmux on this Mac (or the operator prefers ours): use the copy shipped in the app.
            tmuxPath = AppPaths.bundledTmux.path
            usingBundledTmux = true
        } else {
            tmuxPath = nil
            usingBundledTmux = false
        }
        brewPath = ShellEnvironment.which("brew", path: path)
        claudeVersion = claudePath.flatMap { try? Shell.run($0, ["--version"], environment: loginEnvironment, timeout: 10) }
            .flatMap { $0.ok ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        kimiVersion = kimiPath.flatMap { try? Shell.run($0, ["--version"], environment: loginEnvironment, timeout: 10) }
            .flatMap { $0.ok ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        git = Git(executable: ShellEnvironment.which("git", path: path) ?? "/usr/bin/git", environment: loginEnvironment)
        if let tmuxPath {
            let t = LegacyAide.adoptTmuxServer(Tmux(executable: tmuxPath, environment: loginEnvironment))
            tmux = t
            tmuxVersion = t.version()
        } else {
            tmux = nil
            tmuxVersion = nil
        }
    }

    func recheckTools() async {
        detectTools()
        if kimiPath != nil { try? KimiCodeAgent.installConfig(hookBinary: AppPaths.hookBinary.path) }
        let wasReady = isReady
        isReady = tmux != nil && agentPath(for: state.settings.effectiveDefaultAgentID) != nil
        if isReady && !wasReady { restoreSessions() }
    }

    /// Copies the helper binaries from the app bundle to stable locations referenced by agent configs.
    private func installHookBinary() throws {
        try installHelper("artel-hook", to: AppPaths.hookBinary)
        for url in AppPaths.obsolete { try? FileManager.default.removeItem(at: url) }
    }

    func installHelper(_ name: String, to target: URL) throws {
        guard let exe = Bundle.main.executableURL else { return }
        let source = exe.deletingLastPathComponent().appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        if fm.contentsEqual(atPath: source.path, andPath: target.path) { return }
        // Copy then rename: hooks running right now keep executing the old file.
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(name).\(UUID().uuidString)")
        try fm.copyItem(at: source, to: tmp)
        _ = try fm.replaceItemAt(target, withItemAt: tmp)
        chmod(target.path, 0o755)
    }

    private func restoreSessions() {
        guard let tmux else { return }
        let alive = tmux.listSessions()
        for record in state.sessions {
            EventLog.compact(sessionID: record.id)
            var status = EventLog.replay(sessionID: record.id) ?? SessionStatus()
            if alive.contains(record.tmuxName) {
                statuses[record.id] = status
            } else if record.exited {
                status.activity = .exited
                statuses[record.id] = status
            } else {
                statuses[record.id] = status
                relaunch(record)
            }
        }
    }

    // MARK: - Projects

    func addProject(at url: URL) {
        let url = url.standardizedFileURL
        if let existing = state.projects.first(where: { $0.path == url.path }) {
            errorMessage = "Проект «\(existing.name)» уже добавлен."
            return
        }
        let issues = ProjectValidator.issues(at: url)
        if issues.isEmpty {
            insertProject(url: url)
            return
        }
        if issues.contains(.notADirectory) {
            errorMessage = "\(url.path) — не папка."
            return
        }
        let claudeMDURL = url.appendingPathComponent("CLAUDE.md")
        let existing = (try? String(contentsOf: claudeMDURL, encoding: .utf8)) ?? ""
        let text = existing.isEmpty ? ProjectValidator.claudeMDTemplate(projectName: url.lastPathComponent) : existing
        pendingProject = PendingProject(url: url, issues: issues, claudeMD: text)
    }

    /// Finishes adding a pending project: optional `git init`, writes CLAUDE.md.
    func completePendingProject(_ pending: PendingProject, claudeMD: String, initGit: Bool) {
        do {
            if initGit && pending.issues.contains(.notAGitRepository) {
                let git = ShellEnvironment.which("git", path: loginEnvironment["PATH"]) ?? "/usr/bin/git"
                let r = try Shell.run(git, ["init"], environment: loginEnvironment, cwd: pending.url.path)
                guard r.ok else { throw ArtelError.invalidProject("git init: \(r.stderr)") }
            }
            try claudeMD.write(to: pending.url.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
            let remaining = ProjectValidator.issues(at: pending.url)
            guard remaining.isEmpty else {
                errorMessage = remaining.contains(.notAGitRepository)
                    ? "Проект должен быть git-репозиторием." : "Заполните описание проекта в CLAUDE.md."
                return
            }
            pendingProject = nil
            insertProject(url: pending.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func insertProject(url: URL) {
        let used = Set(state.projects.map { ProjectPalette.index($0.colorIndex) })
        let color = (0..<ProjectPalette.colors.count).first { !used.contains($0) } ?? state.projects.count
        let project = Project(name: url.lastPathComponent, path: url.path, colorIndex: color,
                              defaultModel: state.settings.defaultModel(for: state.settings.effectiveDefaultAgentID))
        state.projects.append(project)
        reloadTasks(of: project)
    }

    func removeProject(_ project: Project) {
        if state.sessions.contains(where: { $0.projectID == project.id }) {
            errorMessage = "Сначала остановите сессии проекта «\(project.name)»."
            return
        }
        state.projects.removeAll { $0.id == project.id }
        tasks.removeAll { $0.projectID == project.id }
        noTasks.removeAll { $0.projectID == project.id }
    }

    func updateProject(_ project: Project) {
        guard let i = state.projects.firstIndex(where: { $0.id == project.id }) else { return }
        let old = state.projects[i]
        state.projects[i] = project
        if old.storeArtelInGit != project.storeArtelInGit {
            do { try ArtelGitignore.apply(storeInGit: project.storeArtelInGit, project: project) } catch {
                errorMessage = "Не удалось обновить .gitignore: \(error.localizedDescription)"
            }
        }
        if old.name != project.name { reloadTasks(of: project) }
    }

    func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }

    // MARK: - Sessions

    var selectedTabID: UUID? { state.selectedTabID ?? state.tabs.first?.id }

    func sessions(inTab tabID: UUID?) -> [SessionRecord] {
        let firstTab = state.tabs.first?.id
        let list = state.sessions.filter { ($0.tabID ?? firstTab) == tabID }
        guard state.settings.waitingFirst else { return list }
        // Stable: attention-needing sessions first, otherwise keep creation order.
        return list.enumerated().sorted { a, b in
            let wa = status(a.element.id).activity.needsAttention, wb = status(b.element.id).activity.needsAttention
            return wa != wb ? wa : a.offset < b.offset
        }.map(\.element)
    }

    func sessions(of project: Project) -> [SessionRecord] {
        state.sessions.filter { $0.projectID == project.id }
    }

    var attentionSessions: [SessionRecord] {
        state.sessions.filter { status($0.id).activity.needsAttention }
    }

    func status(_ id: String) -> SessionStatus { statuses[id] ?? SessionStatus() }

    func record(_ id: String) -> SessionRecord? { state.sessions.first { $0.id == id } }

    func nextSessionName(for project: Project) -> String {
        let n = state.sessions.filter { $0.projectID == project.id }.count + 1
        return "\(project.name) #\(n)"
    }

    var lastSessionSettings: SessionLaunchSettings? {
        if let settings = state.lastSessionSettings { return settings }
        return state.sessions.max(by: { $0.createdAt < $1.createdAt }).map(SessionLaunchSettings.init)
    }

    /// ⌘T: start a fresh session with the most recently launched session's settings.
    func repeatLastSession() {
        guard let settings = lastSessionSettings, let project = project(settings.projectID),
              state.settings.isAgentEnabled(settings.agentID) else {
            newSessionRequest = NewSessionRequest(projectID: focusedProjectID)
            return
        }
        section = .sessions
        startSession(project: project, name: nextSessionName(for: project), model: settings.model,
                     permissionMode: settings.permissionMode, prompt: nil, agentID: settings.agentID)
    }

    /// ⌘W: ask before killing the focused agent and closing its card.
    func requestStopSession() {
        guard let id = focusedSessionID ?? state.expandedSessionID else { return }
        sessionToStop = record(id)
    }

    func startSession(project: Project, name: String, model: String?, permissionMode: String, prompt: String?,
                      agentID: String? = nil) {
        let agentID = agentID ?? state.settings.effectiveDefaultAgentID
        guard tmux != nil, agentPath(for: agentID) != nil else {
            errorMessage = "Сначала установите tmux и \(CodingAgents.agent(forID: agentID).displayName)."
            return
        }
        state.lastSessionSettings = SessionLaunchSettings(projectID: project.id, agentID: agentID,
                                                          model: model, permissionMode: permissionMode)
        var record = SessionRecord(name: name, projectID: project.id, cwd: project.path, agentID: agentID,
                                   model: model, permissionMode: permissionMode, tabID: selectedTabID)
        record.conversationID = UUID().uuidString.lowercased()
        state.sessions.append(record)
        archiveSession(record, prompt: prompt)
        saveNow()  // a running tmux session must never be unknown to the state file
        statuses[record.id] = SessionStatus(activity: .starting)
        launch(self.record(record.id) ?? record, resume: false, prompt: prompt)
        focusedSessionID = record.id
    }

    /// Starts the agent again for a session whose process is gone: resume when possible, else fresh.
    func relaunch(_ record: SessionRecord) {
        var record = record
        let sessionAgent = agent(for: record)
        let conversation = record.conversationID ?? status(record.id).claudeSessionID
        let canResume = conversation.map {
            sessionAgent.canResume(conversationID: $0, transcriptPath: status(record.id).transcriptPath, cwd: record.cwd)
        } ?? false
        if !canResume { record.conversationID = UUID().uuidString.lowercased() }
        record.exited = false
        replace(record)
        var s = status(record.id)
        s.activity = .starting
        s.since = Date()
        statuses[record.id] = s
        terminals.discard(record.id)
        terminalEpoch[record.id, default: 0] += 1
        launch(record, resume: canResume, prompt: nil)
    }

    func launch(_ record: SessionRecord, resume: Bool, prompt: String?) {
        let sessionAgent = agent(for: record)
        guard let tmux, let executable = agentPath(for: record.agentID), let conversationID = record.conversationID else { return }
        // A task session may read its task folder (attachments), which lives outside the worktree.
        let addDirs = task(for: record).map { [$0.directory.path] } ?? []
        let spec = LaunchSpec(executable: executable, name: record.name, model: record.model,
                              permissionMode: record.permissionMode, settingsFile: AppPaths.claudeSettings.path,
                              conversationID: conversationID, resume: resume, initialPrompt: prompt, addDirs: addDirs)
        let env = [
            ArtelEnv.sessionID: record.id,
            ArtelEnv.socket: AppPaths.socket.path,
            ArtelEnv.eventsDir: AppPaths.eventsDir.path,
        ]
        do {
            try tmux.newSession(name: record.tmuxName, cwd: record.cwd, env: env, command: sessionAgent.command(for: spec))
            // Interactive kimi takes no prompt in argv: paste it once the TUI is ready.
            if sessionAgent.agentID == KimiCodeAgent.id, let prompt, !prompt.isEmpty, !resume {
                deliverPrompt(prompt, to: record.id)
            }
        } catch {
            var s = status(record.id)
            s.activity = .error
            s.message = error.localizedDescription
            statuses[record.id] = s
        }
    }

    /// Pastes the first prompt into a freshly started kimi TUI, waiting for SessionStart (≈20 s max).
    private func deliverPrompt(_ prompt: String, to sessionID: String) {
        Task { [weak self] in
            var waited = 0
            while waited < 100 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if self.status(sessionID).activity == .ready { break }
                waited += 1
            }
            guard let self, let record = self.record(sessionID) else { return }
            try? self.tmux?.paste(prompt, into: record.tmuxName, submit: true)
        }
    }

    /// Explicit stop: kills the agent and removes the session from the workspace.
    func stopSession(_ id: String) {
        guard let record = record(id) else { return }
        tmux?.kill(record.tmuxName)
        archiveSession(record, captureTranscript: true)
        terminals.discard(id)
        state.sessions.removeAll { $0.id == id }
        statuses.removeValue(forKey: id)
        EventLog.remove(sessionID: id)
        if state.expandedSessionID == id { state.expandedSessionID = nil }
        if focusedSessionID == id { focusedSessionID = nil }
        saveNow()
        updateBadge()
    }

    /// Called by the terminal when its tmux client exits.
    func attachEnded(_ id: String) {
        guard var record = record(id) else { return }
        if tmux?.hasSession(record.tmuxName) == true {
            // Only the client died (e.g. detached); the agent still runs — reattach.
            terminals.discard(id)
            terminalEpoch[id, default: 0] += 1
            return
        }
        record.exited = true
        replace(record)
        var s = status(id)
        if s.activity != .exited {
            s.activity = .exited
            s.since = Date()
            s.detail = nil
        }
        statuses[id] = s
        updateBadge()
    }

    func replace(_ record: SessionRecord) {
        guard let i = state.sessions.firstIndex(where: { $0.id == record.id }) else { return }
        state.sessions[i] = record
    }

    func rename(_ id: String, to name: String) {
        guard var r = record(id), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        r.name = name
        replace(r)
    }

    // MARK: - Hook events

    func handle(_ event: HookEvent) {
        guard let record = record(event.artelSessionID) else { return }
        apply(status(record.id).applying(event), to: record)
        let captureTranscript = ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"].contains(event.name)
        archiveSession(self.record(record.id) ?? record,
                      prompt: event.name == "UserPromptSubmit" ? event.prompt : nil,
                      captureTranscript: captureTranscript)
    }

    private func apply(_ new: SessionStatus, to record: SessionRecord) {
        var record = record
        let old = status(record.id)
        statuses[record.id] = new
        if let conversation = new.claudeSessionID, conversation != record.conversationID {
            record.conversationID = conversation
            replace(record)
        }
        if old.activity != new.activity {
            let notable = new.activity.needsAttention || (new.activity == .idle && old.activity == .working)
            if notable && state.settings.notifications.allows(new.activity) {
                notifier.post(session: record, project: project(record.projectID), status: new,
                              settings: state.settings.notifications)
            }
            updateBadge()
        }
    }

    /// Safety net for missed socket events (app restarted, socket path changed): the per-session
    /// event logs are the source of truth, so re-fold any log that grew since we last looked.
    private var logSizes: [String: UInt64] = [:]
    private var reconcileTimer: Timer?

    private func startReconciling() {
        reconcileTimer?.invalidate()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileLogs() }
        }
    }

    private var pollTick = 0

    private func reconcileLogs() {
        pollTick += 1
        pollTasks(checkGit: pollTick % 5 == 0)
        for record in state.sessions {
            let url = AppPaths.eventsFile(sessionID: record.id)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            guard size != logSizes[record.id] else { continue }
            logSizes[record.id] = size
            guard var replayed = EventLog.replay(sessionID: record.id) else { continue }
            let current = status(record.id)
            // Process exit is known from tmux, not from the log.
            if current.activity != .exited,
               replayed.activity != current.activity || replayed.message != current.message || replayed.detail != current.detail {
                if replayed.activity == current.activity { replayed.since = current.since }
                apply(replayed, to: record)
            }
            archiveSession(self.record(record.id) ?? record,
                          captureTranscript: [.idle, .error, .exited].contains(replayed.activity))
        }
    }

    func updateBadge() {
        let n = attentionSessions.count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: - Focus & layout

    /// `takeKeyboard: false` — only highlight the session (arrow keys in the sidebar), keep keyboard focus where it is.
    func focus(_ id: String, activate: Bool = false, takeKeyboard: Bool = true) {
        guard let record = record(id) else { return }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        section = .sessions
        // The task window is not modal: it stays open, the main window comes forward.
        if let mainWindow, !mainWindow.isKeyWindow { mainWindow.makeKeyAndOrderFront(nil) }
        if let tab = record.tabID, tab != state.selectedTabID { state.selectedTabID = tab }
        if let expanded = state.expandedSessionID, expanded != id { state.expandedSessionID = id }
        focusedSessionID = id
        if takeKeyboard { terminals.focus(id) }
    }

    /// ⌘J: cycles through sessions that need the operator.
    func focusNextAttention() {
        let list = attentionSessions
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == focusedSessionID } ?? -1
        focus(list[(current + 1) % list.count].id)
    }

    func focus(index: Int) {
        let list = sessions(inTab: selectedTabID)
        guard index < list.count else { return }
        focus(list[index].id)
    }

    func toggleExpanded(_ id: String? = nil) {
        guard let id = id ?? focusedSessionID ?? state.expandedSessionID else { return }
        state.expandedSessionID = state.expandedSessionID == id ? nil : id
        focusedSessionID = id
        DispatchQueue.main.async { self.terminals.focus(id) }
    }

    func resize(session id: String, columnSpan: Int, rowSpan: Int) {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        let columns = max(1, columnSpan)
        let rows = max(1, rowSpan)
        guard state.sessions[i].columnSpan != columns || state.sessions[i].rowSpan != rows else { return }
        state.sessions[i].columnSpan = columns
        state.sessions[i].rowSpan = rows
    }

    // MARK: - Tabs

    func addTab() {
        let tab = WorkspaceTab(title: "Вкладка \(state.tabs.count + 1)")
        state.tabs.append(tab)
        state.selectedTabID = tab.id
        state.expandedSessionID = nil
    }

    func selectTab(_ id: UUID) {
        state.selectedTabID = id
        if let expanded = state.expandedSessionID, record(expanded)?.tabID != id { state.expandedSessionID = nil }
    }

    func renameTab(_ id: UUID, to title: String) {
        guard let i = state.tabs.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        state.tabs[i].title = title
    }

    func activeSessions(inTab tabID: UUID) -> [SessionRecord] {
        sessions(inTab: tabID).filter { !$0.exited && status($0.id).activity != .exited }
    }

    func requestCloseTab(_ id: UUID) {
        guard state.tabs.count > 1, let tab = state.tabs.first(where: { $0.id == id }) else { return }
        if activeSessions(inTab: id).isEmpty {
            closeTab(id)
        } else {
            tabToClose = tab
        }
    }

    func closeTab(_ id: UUID) {
        guard state.tabs.count > 1, let i = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        for record in sessions(inTab: id) { stopSession(record.id) }
        state.tabs.remove(at: i)
        if state.selectedTabID == id { state.selectedTabID = state.tabs[max(0, i - 1)].id }
        tabToClose = nil
    }

    func move(session id: String, toTab tabID: UUID) {
        guard var r = record(id) else { return }
        r.tabID = tabID
        replace(r)
        if state.expandedSessionID == id { state.expandedSessionID = nil }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do { try state.save() } catch { errorMessage = "Не удалось сохранить состояние: \(error.localizedDescription)" }
    }

    func shutdown() {
        flushTaskSaves()
        saveTask?.cancel()
        for record in state.sessions where record.taskID == nil {
            archiveSession(record, captureTranscript: true)
        }
        saveNow()
        // Terminal clients exit with the app; tmux keeps the agents running.
        hookServer?.stop()
    }
}
