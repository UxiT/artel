import ArtelCore
import AppKit
import SwiftUI

// IDE-style window ("islands"): a title bar with the project and branch widgets, a rail of section icons on the
// left, and rounded panels on a darker canvas: the tool panel (agent sessions, tasks or projects) and the content.

enum Islands {
    static let radius: CGFloat = 10
    static let gap: CGFloat = 6
    static let railWidth: CGFloat = 46

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Behind the islands: the title bar, the rail and the gaps.
    static let canvas = dynamic(light: rgb(0xE4E6EB), dark: rgb(0x2B2D30))
    static let island = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x1E1F22))
    static let stroke = dynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.06))
    static let hover = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.06))
    static let selection = dynamic(light: rgb(0xD5E1FF), dark: rgb(0x2E436E))
    static let control = dynamic(light: NSColor.black.withAlphaComponent(0.15), dark: NSColor.white.withAlphaComponent(0.16))
}

/// A rounded panel on the canvas. It always takes the size it is given: content wider or taller than that is
/// clipped at the island's edge (pinned to `alignment`) instead of growing the island over its neighbours.
struct Island<Content: View>: View {
    var alignment: Alignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
            .background(Islands.island)
            .clipShape(RoundedRectangle(cornerRadius: Islands.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Islands.radius, style: .continuous).strokeBorder(Islands.stroke))
    }
}

/// A button's label that drops its title in a narrow panel.
struct CompactableLabel: View {
    let title: String
    let systemImage: String
    let compact: Bool

    var body: some View {
        if compact {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
        }
    }
}

/// Outlined button of the tool panel ("Add Folder").
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OutlineButton(configuration: configuration)
    }

    private struct OutlineButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Islands.control : hovering ? Islands.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Islands.control))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// Borderless icon button with a hover background (panel header, title bar).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    /// A toggle that is on: highlighted like a selected row.
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration, size: size, on: on)
    }

    private struct IconButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let on: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .frame(minWidth: size, minHeight: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    configuration.isPressed ? Islands.control : on ? Islands.selection : hovering ? Islands.hover : .clear))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Window chrome

/// Width the traffic lights take at the window's top-left corner (the window hides the system title bar).
let trafficLightsWidth: CGFloat = 78

/// Empty canvas that moves the window when dragged and zooms it on a double click, like a title bar.
struct WindowDragArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { model.mainWindow?.performZoom(nil) }
    }
}

/// The tool panel's header, in the window's top row next to the traffic lights: the section's title, its options
/// and the hide button. The row doubles as the title bar (drag, double click).
struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var visible: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if model.section == .workspace {
                AgentSessionsOptionsMenu()
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { visible = false } } label: {
                Label("Hide", systemImage: "minus")
            }
            .buttonStyle(IconButtonStyle())
            .help("Hide the panel (⌃⌘S, or click the section's icon)")
        }
        .focusEffectDisabled()
        .padding(.leading, trafficLightsWidth)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(WindowDragArea())
    }

    private var title: String {
        switch model.section {
        case .workspace: "Agent Sessions"
        case .tasks: "Tasks"
        case .projects: "Projects"
        }
    }
}

// MARK: - Rail

/// Section icons, then adding a project and a task. Clicking the open section's icon hides or shows its tool panel,
/// as in the IDE. Its empty space moves the window.
struct ToolRail: View {
    @Environment(AppModel.self) private var model
    @Binding var panelVisible: Bool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                RailButton(symbol: section.symbol, selected: model.section == section,
                           help: "\(section.title) (⌥⌘\(index + 1))") {
                    if model.section == section {
                        withAnimation(.easeOut(duration: 0.15)) { panelVisible.toggle() }
                    } else {
                        model.section = section
                        panelVisible = true
                    }
                }
            }
            Rectangle().fill(Islands.control).frame(width: 22, height: 1).padding(.vertical, 4)
            RailButton(symbol: "folder.badge.plus", selected: false, help: "Add a project (⇧⌘O)") {
                ProjectPicker.present(model)
            }
            RailButton(symbol: "square.and.pencil", selected: false, help: "New task (⌘N)") {
                model.requestNewTask()
            }
            .disabled(model.state.projects.isEmpty)
            WindowDragArea()
        }
        .padding(.top, 4)
        .frame(width: Islands.railWidth)
    }
}

private struct RailButton: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(enabled ? 0.75 : 0.3))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor : hovering && enabled ? Islands.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Tool panel

/// The tool panel's body (its header is `PanelHeader`): the section's actions and list, Settings at the bottom.
struct ToolPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var searchFocused: FocusState<Bool>.Binding
    @State private var search = ""
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.section {
            case .workspace:
                AgentSessionsActions(searching: $searching, search: $search)
                    .padding(12)
                ProjectTree(mode: .agentSessions, search: searching ? search : "")
            case .tasks:
                TasksPanelActions(searchFocused: searchFocused)
                    .padding(12)
                ProjectTree(mode: .tasks)
            case .projects:
                ViewThatFits(in: .horizontal) {
                    ProjectsPanelActions(compact: false)
                    ProjectsPanelActions(compact: true)
                }
                .lineLimit(1)
                .padding(12)
                ProjectsList()
            }

            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .focusEffectDisabled()
    }
}

/// Projects section: "Add Folder", then the selected project's Files toggle, code editor, Finder and settings.
private struct ProjectsPanelActions: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 2) {
            Button { ProjectPicker.present(model) } label: {
                CompactableLabel(title: "Add Folder", systemImage: "folder.badge.plus", compact: compact).fixedSize()
            }
            .buttonStyle(OutlineButtonStyle())
            .help("Add a project (⇧⌘O), or drag a folder from Finder")
            Spacer(minLength: 8)
            if let id = model.docsProjectID, let project = model.project(id) {
                Button { model.showsProjectFiles.toggle() } label: {
                    Label("Files", systemImage: "list.bullet.indent")
                }
                .buttonStyle(IconButtonStyle(on: model.showsProjectFiles))
                .help(model.showsProjectFiles ? "Back to documentation" : "Show project files")
                .accessibilityAddTraits(model.showsProjectFiles ? .isSelected : [])
                Button { model.openInEditor(projectID: project.id, root: project.url) } label: {
                    Label("Open Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(IconButtonStyle())
                .help("Open the project in a code editor")
                Button { NSWorkspace.shared.activateFileViewerSelecting([project.url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(IconButtonStyle())
                .help("Show the project folder in Finder")
                Button { model.projectSettingsID = project.id } label: { Label("Project Settings", systemImage: "gearshape") }
                    .buttonStyle(IconButtonStyle())
                    .help("Project settings")
            }
        }
    }
}

/// Tasks section: the task search (⌘F) and the filters, for the board and the list below.
private struct TasksPanelActions: View {
    @Environment(AppModel.self) private var model
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Tasks", text: $model.taskFilter.search)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                if !model.taskFilter.search.isEmpty {
                    Button { model.taskFilter.search = "" } label: {
                        Label("Clear", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Islands.control))
            FilterMenu()
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle(size: 28))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.state.projects.isEmpty)
        }
    }
}

/// "New Session ▾", "Add Folder", the filter and the search of the agent sessions panel.
private struct AgentSessionsActions: View {
    @Environment(AppModel.self) private var model
    @Binding var searching: Bool
    @Binding var search: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // A narrow panel drops the buttons' titles rather than overflowing.
            ViewThatFits(in: .horizontal) {
                buttons(compact: false)
                buttons(compact: true)
            }
            .lineLimit(1)
            if searching {
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onExitCommand { searching = false; search = "" }
            }
        }
    }

    private func buttons(compact: Bool) -> some View {
        HStack(spacing: 8) {
            // Split button: the left part starts a session, the arrow opens the menu.
            HStack(spacing: 0) {
                Button { model.newSessionRequest = NewSessionRequest(projectID: model.currentProject?.id) } label: {
                    CompactableLabel(title: "New Session", systemImage: "asterisk", compact: compact)
                        .fixedSize()
                        .padding(.horizontal, compact ? 7 : 10)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New session without a task (\(AppShortcuts.newSessionWithoutTask.display))")
                Rectangle().fill(Islands.control).frame(width: 1, height: 16)
                Menu {
                    Button("New Task…") { model.requestNewTask() }
                    Divider()
                    ForEach(model.state.projects) { project in
                        Button("New Session in \(project.name)…") {
                            model.newSessionRequest = NewSessionRequest(projectID: project.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Islands.control))
            .disabled(model.state.projects.isEmpty || !model.isReady)

            Button { ProjectPicker.present(model) } label: {
                CompactableLabel(title: "Add Folder", systemImage: "folder", compact: compact).fixedSize()
            }
            .buttonStyle(OutlineButtonStyle())
            .help("Add a project (⇧⌘O), or drag a folder from Finder")

            Spacer(minLength: 0)
            Button {
                searching.toggle()
                if searching { searchFocused = true } else { search = "" }
            } label: { Label("Search", systemImage: "magnifyingglass") }
                .buttonStyle(IconButtonStyle())
                .help("Filter sessions and tasks by name")
        }
    }
}

/// ⋮ menu of the agent sessions panel: what the tree shows.
private struct AgentSessionsOptionsMenu: View {
    @AppStorage(ProjectTree.showTasksKey) private var showTasks = true
    @AppStorage(ProjectTree.showArchivesKey) private var showArchives = true
    @AppStorage(ProjectTree.collapsedKey) private var collapsedRaw = ""
    @AppStorage(ProjectTree.collapsedGroupsKey) private var collapsedGroupsRaw = ""
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Toggle("Show Tasks Without a Session", isOn: $showTasks)
            Toggle("Show Archived Sessions", isOn: $showArchives)
            Divider()
            Button("Expand All") { collapsedRaw = ""; collapsedGroupsRaw = "" }
            Button("Collapse All") { collapsedRaw = model.state.projects.map(\.id.uuidString).sorted().joined(separator: ",") }
        } label: {
            Label("Options", systemImage: "ellipsis").rotationEffect(.degrees(90))
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Panel options")
    }
}

/// Drag handle between the tool panel and the content.
struct PanelResizeHandle: View {
    /// The stored width (the operator's choice).
    @Binding var width: Double
    /// The width shown now (the stored one capped by the window): a drag starts from it.
    var current: Double
    var range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: Islands.gap)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? current
                    start = base
                    width = min(range.upperBound, max(range.lowerBound, base + value.translation.width))
                }
                .onEnded { _ in start = nil })
    }
}

extension AppModel {
    /// The project of the title bar widget: the documentation's project in Projects, else the one picked in the
    /// tree or the focused session's.
    var currentProject: Project? {
        if let id = docsProjectID, let p = project(id) { return p }
        return focusedProjectID.flatMap(project)
    }

    func selectCurrentProject(_ id: UUID) {
        guard id != docsProjectID else { return }
        docsProjectID = id
        docsPath = nil  // the project's docs home page
        docsSearch = ""
    }

    /// Archived sessions without a task of a project, newest first.
    func noTasks(of project: Project) -> [ArtelTask] {
        visibleNoTasks(of: project).sorted { $0.updated > $1.updated }
    }
}
