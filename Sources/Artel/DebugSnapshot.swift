import ArtelCore
import AppKit

/// Development aid: `ARTEL_SNAPSHOT=/path/shot.png` renders the main window to a PNG every few seconds.
/// Uses the app's own view hierarchy, so it needs no screen-recording permission.
enum DebugSnapshot {
    /// Vibrancy (NSVisualEffectView) doesn't render into cacheDisplay; snapshot mode uses solid backgrounds.
    static let enabled = !(ProcessInfo.processInfo.environment["ARTEL_SNAPSHOT"] ?? "").isEmpty

    @MainActor static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["ARTEL_SNAPSHOT"], !path.isEmpty else { return }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { capture(to: URL(fileURLWithPath: path)) }
        }
    }

    @MainActor static func capture(to url: URL, window preferred: NSWindow? = nil) {
        // The given or frontmost window (main, task or settings); an open sheet is a window of its own: capture it instead.
        let front = preferred ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 && $0.sheetParent == nil })
        guard let window = front?.attachedSheet ?? front,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Development aid: `ARTEL_DEBUG_SCRIPT='[{"launch":"ARTEL-1","model":"haiku"}, …]'`
/// runs model actions after start-up, bypassing UI gestures (drag-and-drop can't be scripted from outside).
/// Steps (one key each, plus parameters):
///   wait: seconds · section: sessions|tasks|projects [doc: path] · select: task · launch: task [model, worktree, into (session index), clear]
///   resize: session index [columns, rows] — resize its card in grid cells · draggingTask: bool — show the new-session drop target
///   open: task · close · newTask: title — the task window with a new-task draft · createTask — create the open draft
///   closeTab · confirmCloseTab — request closing the selected tab, then confirm its confirmation dialog
///   openNoTask: session id — open the archived session overview and its files
///   convertNoTask: session id — promote its archive to a numbered done task and open it
///   waitStatus: task + status [timeout] · waitIdle: task [timeout] — the task's session stops working
///   setStatus: task + to (new|in-progress|done) — set the status as the operator; done with a worktree opens its dialog
///   done: task [removeWorktree, deleteBranch] — close the task, bypassing the dialog
///   snapshot: path [of: main|task] — render the frontmost (or the given) window, or the sheet open on it
///   front: main|task — bring that window to the front
///   settings: true — open the Settings window · newSession: true — the new-session sheet
///   launchSheet: task — the launch dialog · projectSettings: project index — its settings sheet
///   commitSheet: project index — the .artel commit sheet · dismiss: true — close sheets and dialogs above
///   addProject: folder path — add it, or open the add-project sheet if it lacks git or CLAUDE.md
///   completeProject: true — finish that sheet without CLAUDE.md and git init
/// Progress is appended to $ARTEL_DEBUG_LOG if set.
enum DebugScript {
    @MainActor static func run(_ model: AppModel) async {
        guard let json = ProcessInfo.processInfo.environment["ARTEL_DEBUG_SCRIPT"],
              let steps = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return }
        for step in steps {
            await perform(step, model)
        }
        log("script finished")
    }

    static func log(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["ARTEL_DEBUG_LOG"] else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @MainActor static func task(_ model: AppModel, _ id: Any?) -> ArtelTask? {
        guard let id = id as? String else { return nil }
        return model.tasks.first { $0.taskID == id }
    }

    @MainActor static func poll(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition()
    }

    @MainActor static func perform(_ step: [String: Any], _ model: AppModel) async {
        let timeout = step["timeout"] as? Double ?? 180
        if let seconds = step["wait"] as? Double {
            try? await Task.sleep(for: .seconds(seconds))
        }
        if step["editors"] != nil {
            let apps = CodeEditors.installed()
            log("editors: " + apps.map { "\($0.name) \($0.version) [\($0.url.path)]" }.joined(separator: "; "))
            for p in model.state.projects {
                let auto = JetBrainsIDE.autoChoice(forProjectAt: p.url, installed: Set(apps.map(\.bundleID)))
                log("project \(p.name): auto = \(auto ?? "ask")")
            }
        }
        if let section = (step["section"] as? String).flatMap(AppSection.init) {
            model.section = section
            if let doc = step["doc"] as? String { model.docsPath = doc }
            log("section \(section.rawValue)")
        }
        if let index = step["resize"] as? Int {
            let sessions = model.sessions(inTab: model.selectedTabID)
            if index >= 0, index < sessions.count {
                let id = sessions[index].id
                let columns = step["columns"] as? Int ?? 1
                let rows = step["rows"] as? Int ?? 1
                model.resize(session: id, columnSpan: columns, rowSpan: rows)
                log("resize \(id): \(columns)×\(rows)")
            }
        }
        if let dragging = step["draggingTask"] as? Bool {
            model.isDraggingTask = dragging
            log("draggingTask \(dragging)")
        }
        if let shot = step["snapshot"] as? String {
            let of = (step["of"] as? String).flatMap { which -> NSWindow? in
                switch which {
                case "task": return model.taskWindow
                case "main": return model.mainWindow
                case "settings": return NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true && $0.isVisible }
                default: return nil
                }
            }
            if let of {
                // An occluded window isn't redrawn: bring it up and let it render first.
                of.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))
            }
            DebugSnapshot.capture(to: URL(fileURLWithPath: shot), window: of)
            let windows = NSApp.orderedWindows.filter(\.isVisible).map { "\($0.title)[\(Int($0.frame.width))]" }
            log("snapshot \((shot as NSString).lastPathComponent) · windows front→back: \(windows.joined(separator: ", "))")
        }
        if let t = task(model, step["open"]) {
            model.openTask(t.id)
            log("open \(t.taskID)")
        }
        if step["close"] != nil {
            model.openedTaskID = nil
            model.openedNoTaskID = nil
            model.newTaskDraft = nil
        }
        if step["closeTab"] != nil, let id = model.selectedTabID {
            model.requestCloseTab(id)
            log("closeTab \(id): confirmation = \(model.tabToClose != nil)")
        }
        if step["confirmCloseTab"] != nil, let tab = model.tabToClose {
            model.closeTab(tab.id)
            log("confirmCloseTab \(tab.id): tabs = \(model.state.tabs.count), sessions = \(model.state.sessions.count)")
        }
        if let id = step["openNoTask"] as? String, let archive = model.noTask(sessionID: id) {
            model.openNoTask(archive.id)
            log("openNoTask \(id)")
        }
        if let id = step["convertNoTask"] as? String {
            model.convertNoTask(sessionID: id)
            log("convertNoTask \(id)")
        }
        if let title = step["newTask"] as? String { model.requestNewTask(title: title) }
        if step["createTask"] != nil, let draft = model.newTaskDraft { model.createTask(draft) }
        if let preview = step["preview"] as? Bool { UserDefaults.standard.set(preview, forKey: MarkdownMode.key) }
        if let which = step["front"] as? String {
            if let w = which == "task" ? model.taskWindow : model.mainWindow, w.isVisible { w.orderFrontRegardless() }
            log("front \(which)")
        }
        if step["settings"] != nil {
            model.debugOpenSettings += 1
            log("settings")
        }
        if step["newSession"] != nil {
            model.newSessionRequest = NewSessionRequest(projectID: model.state.projects.first?.id)
        }
        if let path = step["addProject"] as? String {
            model.addProject(at: URL(fileURLWithPath: path, isDirectory: true))
            log("addProject \(path): \(model.pendingProject?.issues.map { "\($0)" } ?? ["added"])")
        }
        if step["completeProject"] != nil, let pending = model.pendingProject {
            model.completePendingProject(pending, claudeMD: nil, initGit: false)
            log("completeProject → \(model.state.projects.count) projects")
        }
        if let t = task(model, step["launchSheet"]) {
            model.requestLaunch(taskID: t.id, intoSession: nil)
            log("launchSheet \(t.taskID): \(model.taskLaunch != nil)")
        }
        if let i = step["projectSettings"] as? Int, i < model.state.projects.count {
            model.projectSettingsID = model.state.projects[i].id
        }
        if let i = step["commitSheet"] as? Int, i < model.state.projects.count {
            model.commitRequest = CommitRequest(projectID: model.state.projects[i].id,
                                                changes: ["M .artel/tasks/SHOP-1-demo/task.md"], message: "artel: SHOP-1 → in-progress")
        }
        if step["dismiss"] != nil {
            model.pendingProject = nil
            model.newSessionRequest = nil
            model.taskLaunch = nil
            model.projectSettingsID = nil
            model.commitRequest = nil
            model.doneRequest = nil
            model.errorMessage = nil
            for w in NSApp.windows where w.identifier?.rawValue.contains("Settings") == true { w.close() }
        }
        if let t = task(model, step["select"]) {
            model.selectedTaskID = t.id
        }
        if let t = task(model, step["launch"]) {
            let sessions = model.sessions(inTab: model.selectedTabID)
            let into = (step["into"] as? Int).flatMap { $0 < sessions.count ? sessions[$0].id : nil }
            let worktree = step["worktree"] as? Bool ?? false
            model.launch(TaskLaunchRequest(taskID: t.id, sessionID: into), model: step["model"] as? String,
                         saveModel: true, clearContext: step["clear"] as? Bool ?? true, useWorktree: worktree)
            log("launch \(t.taskID)\(worktree ? " worktree" : "")")
            // Let the agent start before the next step looks at its state.
            _ = await poll(30) { model.activeSession(for: t).map { model.status($0.id).activity == .working } ?? false }
        }
        if let id = step["waitStatus"] as? String, let target = (step["status"] as? String).flatMap(TaskStatus.init(stored:)) {
            let ok = await poll(timeout) { task(model, id)?.status == target }
            log("waitStatus \(id) \(target.rawValue): \(ok ? "ok" : "TIMEOUT, now \(task(model, id)?.status.rawValue ?? "?")")")
        }
        if let id = step["waitIdle"] as? String {
            try? await Task.sleep(for: .seconds(3))
            let ok = await poll(timeout) {
                guard let t = task(model, id), let s = model.sessions(for: t).first else { return false }
                return [.idle, .ready, .waitingInput, .exited].contains(model.status(s.id).activity)
            }
            log("waitIdle \(id): \(ok ? "ok" : "TIMEOUT")")
        }
        if let t = task(model, step["setStatus"]), let to = (step["to"] as? String).flatMap(TaskStatus.init(stored:)) {
            model.setStatus(t, to)
            log("status \(t.taskID) → \(task(model, t.taskID)?.status.rawValue ?? "?")")
        }
        if let t = task(model, step["done"]) {
            let remove = step["removeWorktree"] as? Bool ?? false
            model.closeTask(t, stopSessions: true, removeWorktree: remove, deleteBranch: remove && (step["deleteBranch"] as? Bool ?? false))
            log("done \(t.taskID) → \(task(model, t.taskID)?.status.rawValue ?? "?"), worktree \(task(model, t.taskID)?.worktree ?? "—")")
        }
    }
}
