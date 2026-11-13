import ArtelCore
import SwiftUI
import UniformTypeIdentifiers

/// One window structure for every section: a sidebar (tasks and sessions, or projects in the projects section)
/// and a detail column; search, filters and the main actions live in the toolbar.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            if DebugSnapshot.enabled {
                // Snapshots can't draw the floating glass sidebar: lay it out flat so its content is visible.
                HStack(spacing: 0) {
                    sidebar.frame(width: 270)
                    Divider()
                    detail
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
                } detail: {
                    detail
                }
            }
        }
        .navigationTitle(model.section.title)
        .navigationSubtitle(subtitle)
        .toolbar(id: "main") { MainToolbar() }
        .background(WindowReader { window in
            guard model.mainWindow !== window else { return }
            model.mainWindow = window
            if window.isKeyWindow { model.noteKeyWindow(window) }
        })
        .modifier(MainWindowDialogs())
        .onChange(of: model.taskWindowRequest) { _, _ in
            if model.isTaskWindowOpen { openWindow(id: TaskWindowScene.id) }
        }
        .onChange(of: model.isTaskWindowOpen) { _, open in
            if !open { dismissWindow(id: TaskWindowScene.id) }
        }
        .onChange(of: model.debugOpenSettings) { _, _ in openSettings() }
        .onChange(of: model.focusRequest) { _, request in
            guard request == .search else { return }
            // The search field appears with the section: give it a moment after a section switch.
            DispatchQueue.main.async {
                searchFocused = true
                model.focusRequest = nil
            }
        }
    }

    @ViewBuilder private var sidebar: some View {
        if model.section == .projects {
            ProjectListSidebar()
        } else {
            SidebarView()
        }
    }

    @ViewBuilder private var detail: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SetupBanner()
            switch model.section {
            case .sessions:
                WorkspaceView().searchable(text: $model.taskFilter.search, placement: .toolbar, prompt: "Поиск задач")
                    .searchFocused($searchFocused)
            case .tasks:
                TaskBoardView().searchable(text: $model.taskFilter.search, placement: .toolbar, prompt: "Поиск задач")
                    .searchFocused($searchFocused)
            case .projects:
                ProjectsView()
            }
            Divider()
            StatusBar()
        }
    }

    /// Projects: the project's folder. Elsewhere: how many sessions wait for the operator.
    private var subtitle: String {
        if model.section == .projects {
            return model.docsProjectID.flatMap(model.project)?.path ?? ""
        }
        let waiting = model.attentionSessions.count
        return waiting > 0 ? "Ждут ответа: \(waiting)" : ""
    }
}

/// Sheets and confirmation dialogs of the main window.
private struct MainWindowDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.pendingProject) { AddProjectSheet(pending: $0) }
            .sheet(item: $model.newSessionRequest) { NewSessionSheet(request: $0) }
            .sheet(item: $model.installRequest) { InstallSheet(request: $0) }
            .sheet(item: $model.commitRequest) { CommitSheet(request: $0) }
            .sheet(item: Binding(
            get: { model.projectSettingsID.flatMap { model.project($0) } },
            set: { model.projectSettingsID = $0?.id }
        )) { ProjectSettingsSheet(project: $0) }
            .sheet(isPresented: Binding(get: { model.newTaskDraft != nil && !(model.newTaskInTaskWindow && model.isTaskWindowOpen) },
                                    set: { if !$0 { model.newTaskDraft = nil } })) {
            if let draft = model.newTaskDraft { NewTaskSheet(draft: draft) }
        }
            .modifier(TaskFlowSheets(host: .main))
            .confirmationDialog(
            "Остановить сессию «\(model.sessionToStop?.name ?? "")»?",
            isPresented: Binding(get: { model.sessionToStop != nil }, set: { if !$0 { model.sessionToStop = nil } }),
            titleVisibility: .visible
        ) {
            Button("Остановить", role: .destructive) {
                if let s = model.sessionToStop { model.stopSession(s.id) }
                model.sessionToStop = nil
            }
        } message: {
            if model.sessionToStop?.taskID == nil {
                Text("Процесс агента будет завершён, сессия исчезнет из рабочей области. Лог останется в архиве «Без задачи» на 7 дней.")
            } else {
                Text("Процесс агента будет завершён, сессия исчезнет из рабочей области. Разговор останется в истории агента.")
            }
        }
            .confirmationDialog(
            "Закрыть вкладку «\(model.tabToClose?.title ?? "")»?",
            isPresented: Binding(get: { model.tabToClose != nil }, set: { if !$0 { model.tabToClose = nil } }),
            titleVisibility: .visible
        ) {
            Button("Закрыть и остановить", role: .destructive) {
                if let tab = model.tabToClose { model.closeTab(tab.id) }
                model.tabToClose = nil
            }
        } message: {
            if let tab = model.tabToClose {
                let active = model.activeSessions(inTab: tab.id).count
                Text("Активных сессий: \(active). Все сессии вкладки будут принудительно завершены и удалены из рабочей области.")
            }
        }
    }
}

/// Main window toolbar: section switcher in the centre, the frequent actions on the right.
/// Customizable (right-click the toolbar); "Добавить проект" is available there but hidden by default.
private struct MainToolbar: CustomizableToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some CustomizableToolbarContent {
        @Bindable var model = model
        ToolbarItem(id: "section", placement: .principal) {
            Picker("Раздел", selection: $model.section) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .help("Сессии ⌥⌘1 · Задачи ⌥⌘2 · Проекты ⌥⌘3")
        }
        ToolbarItem(id: "filter", placement: .primaryAction) {
            FilterMenu()
                .disabled(model.section == .projects || model.state.projects.isEmpty)
        }
        ToolbarItem(id: "projectActions", placement: .primaryAction) {
            ProjectToolbarActions()
        }
        ToolbarItem(id: "addProject", placement: .primaryAction, showsByDefault: false) {
            Button { ProjectPicker.present(model) } label: { Label("Добавить проект", systemImage: "folder.badge.plus") }
                .help("Добавить проект (⇧⌘O)")
        }
        ToolbarItem(id: "newSession", placement: .primaryAction) {
            Button { model.newSessionRequest = NewSessionRequest(projectID: model.focusedProjectID) } label: {
                Label("Новая сессия", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Новая сессия без задачи (\(AppShortcuts.newSessionWithoutTask.display))")
            .disabled(model.state.projects.isEmpty || !model.isReady)
        }
        ToolbarItem(id: "newTask", placement: .primaryAction) {
            Button { model.requestNewTask() } label: { Label("Новая задача", systemImage: "square.and.pencil") }
                .help("Новая задача (⌘N)")
                .disabled(model.state.projects.isEmpty)
        }
    }
}

/// Projects section: open the code, reveal in Finder, project settings — for the selected project.
private struct ProjectToolbarActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.section == .projects, let id = model.docsProjectID, let project = model.project(id) {
            ControlGroup {
                Button { model.openInEditor(projectID: project.id, root: project.url) } label: {
                    Label("Открыть код", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Открыть проект в редакторе кода")
                Button { NSWorkspace.shared.activateFileViewerSelecting([project.url]) } label: {
                    Label("Показать в Finder", systemImage: "folder")
                }
                .help("Показать папку проекта в Finder")
                Button { model.projectSettingsID = project.id } label: { Label("Настройки проекта", systemImage: "gearshape") }
                    .help("Настройки проекта")
            }
        }
    }
}

/// Shown when tmux or the default agent's CLI is missing.
struct SetupBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.isBootstrapping && !model.isReady {
            VStack(alignment: .leading, spacing: 8) {
                if model.tmuxPath == nil {
                    row(icon: "terminal", text: "tmux не найден — он держит сессии агентов живыми между запусками Artel.") {
                        if model.brewPath != nil {
                            Button("Установить tmux") {
                                model.installRequest = InstallRequest(title: "Установка tmux", command: "brew install tmux")
                            }
                        } else {
                            Text("Установите Homebrew (brew.sh), затем `brew install tmux`").font(.caption)
                        }
                    }
                }
                if model.claudePath == nil && model.needsAgent(ClaudeCodeAgent.id) {
                    row(icon: "sparkles", text: "Claude Code (claude) не найден.") {
                        Button("Установить Claude Code") {
                            model.installRequest = InstallRequest(
                                title: "Установка Claude Code",
                                command: "curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude --version")
                        }
                    }
                }
                if model.kimiPath == nil && model.needsAgent(KimiCodeAgent.id) {
                    row(icon: "moon.stars", text: "Kimi Code (kimi) не найден.") {
                        Button("Установить Kimi Code") {
                            model.installRequest = InstallRequest(
                                title: "Установка Kimi Code",
                                command: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash && kimi --version")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Проверить снова") { Task { await model.recheckTools() } }
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
        }
    }

    private func row<A: View>(icon: String, text: String, @ViewBuilder action: () -> A) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text)
            Spacer()
            action()
        }
    }
}

/// Bottom bar: session counters and subscription limits.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let all = model.state.sessions.map { model.status($0.id).activity }
        HStack(spacing: 14) {
            label(.working, all.filter { $0 == .working }.count)
            label(.waitingInput, all.filter { $0.needsAttention }.count, title: "ждут ответа")
            label(.idle, all.filter { $0 == .idle }.count)
            Text("всего \(all.count)").foregroundStyle(.tertiary)
            Spacer()
            if model.isBootstrapping {
                ProgressView().controlSize(.small)
                Text("Подготовка окружения…")
            } else if model.state.settings.limits.enabled {
                LimitsIndicator().fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Строка состояния")
    }

    private func label(_ activity: SessionActivity, _ n: Int, title: String? = nil) -> some View {
        Label {
            Text("\(title ?? activity.title): \(n)")
        } icon: {
            Image(systemName: activity.symbol).foregroundStyle(n > 0 ? activity.color : .secondary)
        }
        .labelStyle(.titleAndIcon)
    }
}

extension AppModel {
    /// Project to preselect for a new session: the focused session's, else the first.
    var focusedProjectID: UUID? {
        focusedSessionID.flatMap { record($0)?.projectID } ?? state.projects.first?.id
    }
}

/// Accepts folders dropped from Finder as new projects.
struct FolderDropModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                guard let first = folders.first else { return false }
                model.addProject(at: first)
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                }
            }
    }
}
