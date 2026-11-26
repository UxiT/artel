import ArtelCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window, IDE style (see `IslandsLayout.swift`): the title bar on top, the section rail on the left,
/// the section's tool panel and the content as rounded islands, the status bar at the bottom.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("islands.panelVisible") private var panelVisible = true
    @AppStorage("islands.panelWidth") private var panelWidth = 360.0
    @FocusState private var searchFocused: Bool

    var body: some View {
        // The system titlebar's height (the top safe area): the bar matches it, so the traffic lights sit centred.
        GeometryReader { geo in
            layout(titleBarHeight: max(28, geo.safeAreaInsets.top), width: geo.size.width)
                .ignoresSafeArea(.container, edges: .top)
        }
        .navigationTitle(model.section.title)
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
            panelVisible = true  // the task search is in the tool panel
            // The search field appears with the section: give it a moment after a section switch.
            DispatchQueue.main.async {
                searchFocused = true
                model.focusRequest = nil
            }
        }
    }

    /// The panel never takes the content below this width.
    private static let minContentWidth = 420.0
    private static let minPanelWidth = 240.0

    private func layout(titleBarHeight: CGFloat, width: CGFloat) -> some View {
        // The panel's width is capped by what the window leaves after the rail and the content's minimum.
        let maxPanel = max(Self.minPanelWidth, width - Islands.railWidth - Islands.gap * 2 - Self.minContentWidth)
        let shownPanel = min(max(panelWidth, Self.minPanelWidth), maxPanel)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Left column: the top row (traffic lights, then the panel's header) over the rail and the panel.
                VStack(spacing: 0) {
                    Group {
                        if panelVisible {
                            PanelHeader(visible: $panelVisible)
                        } else {
                            WindowDragArea()
                        }
                    }
                    .frame(height: titleBarHeight)
                    HStack(spacing: 0) {
                        ToolRail(panelVisible: $panelVisible)
                            .fixedSize(horizontal: true, vertical: false)
                        if panelVisible {
                            Island(alignment: .topLeading) { ToolPanel(searchFocused: $searchFocused) }
                                .frame(width: shownPanel)
                        }
                    }
                }
                .frame(width: Islands.railWidth + (panelVisible ? shownPanel : 0))
                if panelVisible {
                    PanelResizeHandle(width: $panelWidth, current: shownPanel, range: Self.minPanelWidth...maxPanel)
                }
                // Up to the window's top edge; with the panel hidden it starts below the traffic lights.
                Island { detail }
                    .padding(.top, panelVisible ? Islands.gap : titleBarHeight)
            }
            .padding(.trailing, Islands.gap)
            // Pinned to the left edge: if the content still doesn't fit, it overflows to the right and is clipped,
            // instead of an HStack centring its overflow and pushing the rail out of the window.
            .frame(width: width, alignment: .leading)
            .clipped()
            StatusBar()
        }
        .background(Islands.canvas)
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            SetupBanner()
            switch model.section {
            case .workspace:
                WorkspaceView()
            case .tasks:
                TaskBoardView()
            case .projects:
                ProjectsView()
            }
        }
    }
}

/// Sheets and confirmation dialogs of the main window.
private struct MainWindowDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            // A new identity per request: the sheet may be swapped to another folder without closing, keeping @State.
            .sheet(item: $model.pendingProject) { AddProjectSheet(pending: $0).id($0.id) }
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
            "Stop Session “\(model.sessionToStop?.name ?? "")”?",
            isPresented: Binding(get: { model.sessionToStop != nil }, set: { if !$0 { model.sessionToStop = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) {
                if let s = model.sessionToStop { model.stopSession(s.id) }
                model.sessionToStop = nil
            }
        } message: {
            if model.sessionToStop?.taskID == nil {
                Text("The agent process will be terminated and the session removed from the workspace. Its log stays in the No Task archive for 7 days.")
            } else {
                Text("The agent process will be terminated and the session removed from the workspace. The conversation stays in the agent's history.")
            }
        }
            .confirmationDialog(
            "Close Tab “\(model.tabToClose?.title ?? "")”?",
            isPresented: Binding(get: { model.tabToClose != nil }, set: { if !$0 { model.tabToClose = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close and Stop", role: .destructive) {
                if let tab = model.tabToClose { model.closeTab(tab.id) }
                model.tabToClose = nil
            }
        } message: {
            if let tab = model.tabToClose {
                let active = model.activeSessions(inTab: tab.id).count
                Text("Active sessions: \(active). All sessions in this tab will be force-stopped and removed from the workspace.")
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
                    row(icon: "terminal", text: "tmux not found. It keeps agent sessions alive between Artel launches.") {
                        if model.brewPath != nil {
                            Button("Install tmux") {
                                model.installRequest = InstallRequest(title: "Installing tmux", command: "brew install tmux")
                            }
                        } else {
                            Text("Install Homebrew (brew.sh), then run `brew install tmux`").font(.caption)
                        }
                    }
                }
                if model.claudePath == nil && model.needsAgent(ClaudeCodeAgent.id) {
                    row(icon: "sparkles", text: "Claude Code (claude) not found.") {
                        Button("Install Claude Code") {
                            model.installRequest = InstallRequest(
                                title: "Installing Claude Code",
                                command: "curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude --version")
                        }
                    }
                }
                if model.kimiPath == nil && model.needsAgent(KimiCodeAgent.id) {
                    row(icon: "moon.stars", text: "Kimi Code (kimi) not found.") {
                        Button("Install Kimi Code") {
                            model.installRequest = InstallRequest(
                                title: "Installing Kimi Code",
                                command: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash && kimi --version")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Check Again") { Task { await model.recheckTools() } }
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
            label(.waitingInput, all.filter { $0.needsAttention }.count, title: "waiting for you")
            label(.idle, all.filter { $0 == .idle }.count)
            Text("total \(all.count)").foregroundStyle(.tertiary)
            Spacer()
            if model.isBootstrapping {
                ProgressView().controlSize(.small)
                Text("Preparing environment…")
            } else if model.state.settings.limits.enabled {
                LimitsIndicator().fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
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
