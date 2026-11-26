import ArtelCore
import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider()
            Group {
                if let id = model.state.expandedSessionID, let record = model.record(id) {
                    HStack(spacing: 8) {
                        SessionCard(record: record, expanded: true)
                            .padding(8)
                        if model.isDraggingTask {
                            NewSessionTile()
                                .frame(width: 110)
                                .padding([.trailing, .vertical], 8)
                        }
                    }
                } else {
                    SessionGrid(sessions: model.sessions(inTab: model.selectedTabID))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}

/// Workspace tabs. A tab is a button (selects), double click or the context menu renames it,
/// the close button appears on hover or on the selected tab, and never on the last one.
struct TabBar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var draft = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.state.tabs) { tab in
                    TabButton(tab: tab, renaming: $renaming, draft: $draft)
                }
                Button { model.addTab() } label: { Label("New Tab", systemImage: "plus").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("New tab (⌥⌘T)")
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tabs")
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    let tab: WorkspaceTab
    @Binding var renaming: UUID?
    @Binding var draft: String
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let selected = tab.id == model.selectedTabID
        let sessions = model.sessions(inTab: tab.id)
        let waiting = sessions.filter { model.status($0.id).activity.needsAttention }.count
        let closable = model.state.tabs.count > 1
        HStack(spacing: 6) {
            if renaming == tab.id {
                TextField("Tab Name", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { renaming = nil }
                    .onAppear { fieldFocused = true }
            } else {
                Button { model.selectTab(tab.id) } label: {
                    HStack(spacing: 6) {
                        Text(tab.title)
                        Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if waiting > 0 {
                            Label("\(waiting)", systemImage: SessionActivity.waitingInput.symbol)
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                                .foregroundStyle(.white)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming() })
                .accessibilityLabel(tab.title)
                .accessibilityValue("sessions: \(sessions.count)\(waiting > 0 ? ", waiting for you: \(waiting)" : "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityAction(named: "Rename") { startRenaming() }
            }
            if closable {
                Button { model.requestCloseTab(tab.id) } label: {
                    Label("Close Tab", systemImage: "xmark").labelStyle(.iconOnly).font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close tab")
                .focusable(false)
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityHidden(!(hovering || selected))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.2) : hovering ? Color.secondary.opacity(0.1) : Color.clear))
        .onHover { hovering = $0 }
        // Drop a session card's header here to move it to this tab.
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, model.record(id) != nil else { return false }
            model.move(session: id, toTab: tab.id)
            return true
        }
        .contextMenu {
            Button("Rename") { startRenaming() }
            Button("Close Tab", role: .destructive) { model.requestCloseTab(tab.id) }
                .disabled(!closable)
        }
    }

    private func startRenaming() {
        draft = tab.title
        renaming = tab.id
    }

    private func commit() {
        model.renameTab(tab.id, to: draft)
        renaming = nil
    }
}

struct SessionGrid: View {
    @Environment(AppModel.self) private var model
    let sessions: [SessionRecord]
    private let plusWidth = 110.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let spacing = GridLayout.spacing
            let height = geo.size.height - spacing * 2
            if sessions.isEmpty {
                if model.isDraggingTask {
                    NewSessionTile().padding(spacing)
                } else {
                    ContentUnavailableView("No Sessions", systemImage: "rectangle.on.rectangle",
                                           description: Text("Create a session with the toolbar button or drag a task here."))
                }
            } else {
                let reserved = model.isDraggingTask ? plusWidth + spacing * 3 : spacing * 2
                let available = geo.size.width - reserved - scrollerWidth
                let spans = sessions.map { GridSpan(columns: $0.columnSpan, rows: $0.rowSpan) }
                let layout = GridLayout.compute(spans: spans, width: available, height: height)
                HStack(alignment: .top, spacing: spacing) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
                                ForEach(layout.placements, id: \.index) { placement in
                                    ResizableSessionCard(record: sessions[placement.index], layout: layout, placement: placement)
                                }
                            }
                            .frame(width: available, height: max(height, layout.contentHeight), alignment: .topLeading)
                            .padding([.leading, .vertical], spacing)
                        }
                        .onChange(of: model.focusedSessionID) { _, id in
                            guard let id, sessions.contains(where: { $0.id == id }) else { return }
                            if reduceMotion { proxy.scrollTo(id) } else { withAnimation { proxy.scrollTo(id) } }
                        }
                    }
                    if model.isDraggingTask {
                        NewSessionTile()
                            .frame(width: plusWidth, height: height)
                            .padding([.trailing, .vertical], spacing)
                    }
                }
            }
        }
    }

    /// Room for a legacy (always visible) scroller so cards don't get clipped.
    private var scrollerWidth: Double {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

private struct ResizableSessionCard: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    let layout: ArtelCore.GridLayout
    let placement: GridPlacement
    @State private var dragStart: GridSpan?

    var body: some View {
        SessionCard(record: record, expanded: false)
            .frame(width: layout.width(for: placement), height: layout.height(for: placement))
            .offset(x: layout.x(for: placement), y: layout.y(for: placement))
            .id(record.id)
            .overlay(alignment: .trailing) {
                SessionResizeHandle(cursor: .resizeLeftRight, help: "Resize width") {
                    resize($0, horizontally: true, vertically: false)
                } onEnded: {
                    dragStart = nil
                }
                .frame(width: 14)
            }
            .overlay(alignment: .bottom) {
                SessionResizeHandle(cursor: .resizeUpDown, help: "Resize height") {
                    resize($0, horizontally: false, vertically: true)
                } onEnded: {
                    dragStart = nil
                }
                .frame(height: 14)
            }
            .overlay(alignment: .bottomTrailing) {
                SessionResizeHandle(cursor: .frameResize(position: .bottomRight, directions: .all), help: "Resize",
                                    glyph: true) {
                    resize($0, horizontally: true, vertically: true)
                } onEnded: {
                    dragStart = nil
                }
                .frame(width: 18, height: 18)
            }
    }

    private func resize(_ translation: CGSize, horizontally: Bool, vertically: Bool) {
        let start = dragStart ?? GridSpan(columns: record.columnSpan, rows: record.rowSpan)
        if dragStart == nil { dragStart = start }
        let columnDelta = horizontally ? Int((translation.width / (layout.cardWidth + GridLayout.spacing)).rounded()) : 0
        let rowDelta = vertically ? Int((translation.height / (layout.cardHeight + GridLayout.spacing)).rounded()) : 0
        model.resize(session: record.id,
                     columnSpan: min(layout.columns, max(1, start.columns + columnDelta)),
                     rowSpan: max(1, start.rows + rowDelta))
    }
}

private struct SessionResizeHandle: View {
    let cursor: NSCursor
    let help: String
    var glyph = false
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
    @State private var hovering = false

    init(cursor: NSCursor, help: String, glyph: Bool = false,
         onChanged: @escaping (CGSize) -> Void, onEnded: @escaping () -> Void) {
        self.cursor = cursor
        self.help = help
        self.glyph = glyph
        self.onChanged = onChanged
        self.onEnded = onEnded
    }

    var body: some View {
        Rectangle()
            .fill(hovering && !glyph ? Color.accentColor.opacity(0.3) : Color.clear)
            .overlay(alignment: .bottomTrailing) {
                if glyph && hovering {
                    Image(systemName: "arrow.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { cursor.set() } else { NSCursor.arrow.set() }
            }
            .onDisappear {
                if hovering { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onChanged($0.translation) }
                    .onEnded { _ in onEnded() }
            )
            .help(help)
    }
}

/// Drop target shown only while a task is being dragged.
struct NewSessionTile: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button {
            model.newSessionRequest = NewSessionRequest(projectID: model.focusedProjectID)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.largeTitle.weight(.light))
                Text(model.state.projects.isEmpty ? "Add a project first"
                     : targeted ? "Launch the task in a new session" : "Drop a task\ninto a new session")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(hovering || targeted ? .primary : .secondary)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A floating drop target, not content: glass, tinted while a task hovers over it.
            .glassEffect(targeted ? .regular.tint(Color.accentColor.opacity(0.35)).interactive() : .regular.interactive(),
                         in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [6, 4]))
                    .foregroundStyle(hovering || targeted ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.state.projects.isEmpty || !model.isReady)
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(DragPayload.taskID(from:)).first else { return false }
            model.requestLaunch(taskID: id, intoSession: nil)
            return true
        } isTargeted: { targeted = $0 }
    }
}
