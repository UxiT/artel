import ArtelCore
import AppKit
import SwiftUI

struct AppShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    var display: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + String(key.character).uppercased()
    }
}

enum AppShortcuts {
    static let newSessionWithoutTask = AppShortcut(key: "t", modifiers: [.command, .shift])
}

@main
struct ArtelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("Artel", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                    await DebugScript.run(model)
                }
        }
        .defaultSize(width: 1500, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { ArtelCommands(model: model, updater: updater) }

        // The task window: not modal, so sessions stay usable while a task is open.
        Window("Task", id: TaskWindowScene.id) {
            TaskWindowScene()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 820)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 680)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run): become a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.startIfRequested()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.model?.noteKeyWindow(window) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.model?.taskWindowWillClose(window) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Unsaved documents (task texts, documentation pages): save, drop or stay.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.dirtyDocuments.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(model.dirtyDocuments.count) \(model.dirtyDocuments.count == 1 ? "document" : "documents")?"
        alert.informativeText = "You have unsaved edits in task texts or documentation pages."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.saveAllDrafts() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

struct ArtelCommands: Commands {
    let model: AppModel
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isEnabled { CheckForUpdatesButton(updater: updater) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Task…") { model.requestNewTask() }
                .keyboardShortcut("n")
                .disabled(model.state.projects.isEmpty)
            Button("New Session with Same Settings") { model.repeatLastSession() }
                .keyboardShortcut("t")
                .disabled(model.state.projects.isEmpty)
            Button("New Session Without Task…") { model.newSessionRequest = NewSessionRequest(projectID: model.focusedProjectID) }
                .keyboardShortcut(AppShortcuts.newSessionWithoutTask.key, modifiers: AppShortcuts.newSessionWithoutTask.modifiers)
                .disabled(model.state.projects.isEmpty)
            Button("Add Project…") { ProjectPicker.present(model) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Tab") { model.addTab() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W closes the focused session in the main window (deliberate), and the window anywhere else.
            Button(model.closeCommandTitle) { model.closeCommand() }
                .keyboardShortcut("w")
                .disabled(model.closeCommandDisabled)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, section in
                Button(section.title) { model.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Divider()
        }
        CommandGroup(replacing: .sidebar) {
            // The main window's tool panel (`ContentView` keeps it in the same defaults key).
            Button("Show / Hide Tool Panel") {
                let key = "islands.panelVisible"
                UserDefaults.standard.set(!(UserDefaults.standard.object(forKey: key) as? Bool ?? true), forKey: key)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandMenu("Tasks") {
            Button("Search") { model.request(focus: .search) }
                .keyboardShortcut("f")
            Button("Launch Selected Task…") {
                if let id = model.selectedTaskID { model.requestLaunch(taskID: id, intoSession: nil) }
            }
            .keyboardShortcut("r")
            .disabled(model.selectedTaskID == nil)
            Button("Open Task") { if let id = model.selectedTaskID { model.openTask(id) } }
                .keyboardShortcut("o")
                .disabled(model.selectedTaskID == nil)
            Divider()
            Button("Commit Tasks (.artel)…") {
                if let id = model.focusedOrSelectedProjectID { model.requestCommit(projectID: id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model.state.projects.isEmpty)
        }
        CommandMenu("Workspace") {
            Button("Next Session Waiting for You") { model.focusNextAttention() }
                .keyboardShortcut("j")
                .disabled(model.attentionSessions.isEmpty)
            Button("Expand / Collapse") { model.toggleExpanded() }
                .keyboardShortcut(.return)
            Divider()
            ForEach(0..<9) { i in
                Button("Session \(i + 1)") { model.focus(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button("Stop Session…") { model.requestStopSession() }
                .keyboardShortcut(".")
                .disabled(model.focusedSessionID == nil && model.state.expandedSessionID == nil)
        }
    }
}

enum ProjectPicker {
    @MainActor static func present(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK, let url = panel.url { model.addProject(at: url) }
    }
}
