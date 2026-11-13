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
        .windowToolbarStyle(.unified)
        .commands { ArtelCommands(model: model, updater: updater) }

        // The task window: not modal, so sessions stay usable while a task is open.
        Window("Задача", id: TaskWindowScene.id) {
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
}

struct ArtelCommands: Commands {
    let model: AppModel
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isEnabled { CheckForUpdatesButton(updater: updater) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Новая задача…") { model.requestNewTask() }
                .keyboardShortcut("n")
                .disabled(model.state.projects.isEmpty)
            Button("Новая сессия с теми же настройками") { model.repeatLastSession() }
                .keyboardShortcut("t")
                .disabled(model.state.projects.isEmpty)
            Button("Новая сессия без задачи…") { model.newSessionRequest = NewSessionRequest(projectID: model.focusedProjectID) }
                .keyboardShortcut(AppShortcuts.newSessionWithoutTask.key, modifiers: AppShortcuts.newSessionWithoutTask.modifiers)
                .disabled(model.state.projects.isEmpty)
            Button("Добавить проект…") { ProjectPicker.present(model) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Новая вкладка") { model.addTab() }
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
        CommandMenu("Задачи") {
            Button("Поиск задач") { model.request(focus: .search) }
                .keyboardShortcut("f")
            Button("Запустить выбранную задачу…") {
                if let id = model.selectedTaskID { model.requestLaunch(taskID: id, intoSession: nil) }
            }
            .keyboardShortcut("r")
            .disabled(model.selectedTaskID == nil)
            Button("Открыть задачу") { if let id = model.selectedTaskID { model.openTask(id) } }
                .keyboardShortcut("o")
                .disabled(model.selectedTaskID == nil)
            Divider()
            Button("Закоммитить задачи (.artel)…") {
                if let id = model.focusedOrSelectedProjectID { model.requestCommit(projectID: id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model.state.projects.isEmpty)
        }
        CommandMenu("Сессии") {
            Button("Следующая, ждущая ответа") { model.focusNextAttention() }
                .keyboardShortcut("j")
                .disabled(model.attentionSessions.isEmpty)
            Button("Развернуть / свернуть") { model.toggleExpanded() }
                .keyboardShortcut(.return)
            Divider()
            ForEach(0..<9) { i in
                Button("Сессия \(i + 1)") { model.focus(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button("Остановить сессию…") { model.requestStopSession() }
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
        panel.prompt = "Добавить"
        panel.message = "Выберите папку проекта"
        if panel.runModal() == .OK, let url = panel.url { model.addProject(at: url) }
    }
}
