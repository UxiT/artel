import ArtelCore
import SwiftUI

struct SessionCard: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    let expanded: Bool
    @State private var dropTargeted = false
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let status = model.status(record.id)
        let focused = model.focusedSessionID == record.id
        VStack(spacing: 0) {
            header(status)
            if status.activity == .starting {
                // Re-evaluated over time: the hint appears only if the agent stays silent.
                TimelineView(.periodic(from: .now, by: 2)) { ctx in
                    if let line = messageLine(status, now: ctx.date) {
                        MessageLine(text: line, activity: status.activity)
                    }
                }
            } else if let line = messageLine(status, now: Date()) {
                MessageLine(text: line, activity: status.activity)
            }
            ZStack {
                if status.activity == .exited {
                    ExitedOverlay(record: record)
                } else {
                    TerminalHost(record: record, epoch: model.terminalEpoch[record.id, default: 0])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.09, alpha: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor(status, focused: focused), lineWidth: status.activity.needsAttention || focused ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .onHover { hovering = $0 }
        .overlay {
            if dropTargeted { DropHint(accepts: AppModel.canReceiveTask(status.activity)) }
        }
        // Drop a task here to run it in this session (only when nothing is running).
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(DragPayload.taskID(from:)).first else { return false }
            model.requestLaunch(taskID: id, intoSession: record.id)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func borderColor(_ status: SessionStatus, focused: Bool) -> Color {
        if status.activity.needsAttention { return status.activity.color }
        return focused ? Color.accentColor : HairlineColor.border(contrast)
    }

    /// Left: project, task id, title (gets the room). Right: status and time; expand / stop appear on hover or focus.
    private func header(_ status: SessionStatus) -> some View {
        let project = model.project(record.projectID)
        let task = model.task(for: record)
        let title = task?.title ?? record.name
        let modelName = record.model.flatMap { $0.isEmpty ? nil : $0 }
        let focused = model.focusedSessionID == record.id
        let details = [project?.name, modelName.map { "модель \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 7) {
            ProjectBadge(project: project, size: 15)
            if let task {
                Button {
                    model.openTask(task.id)
                } label: {
                    Text(task.taskID).font(.caption.monospaced().bold())
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("\(task.title) — \(task.status.title). Открыть задачу")
                .accessibilityLabel("Открыть задачу \(task.taskID)")
            }
            Text(title).font(.headline).lineLimit(1).layoutPriority(1)
                .help([title, details].filter { !$0.isEmpty }.joined(separator: "\n"))
            // Project and model only when there is room for them next to the title.
            ViewThatFits(in: .horizontal) {
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 6)
            ActivityCapsule(activity: status.activity)
            SinceText(date: status.since).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).fixedSize()
            if hovering || focused || expanded {
                CardControls(record: record, expanded: expanded)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hovering || focused)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleExpanded(record.id) }
        .simultaneousGesture(TapGesture().onEnded { model.focus(record.id) })
        // Drag the header onto a workspace tab to move the session there.
        .draggable(record.id) {
            Label(record.name, systemImage: "rectangle.on.rectangle").padding(6)
        }
        .contextMenu { SessionMenu(record: record) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.activity.title)\(details.isEmpty ? "" : ", \(details)")")
        .accessibilityAction(named: expanded ? "Свернуть" : "Развернуть") { model.toggleExpanded(record.id) }
        .accessibilityAction(named: "Остановить сессию") { model.sessionToStop = record }
    }

    private func messageLine(_ status: SessionStatus, now: Date) -> String? {
        switch status.activity {
        case .starting:
            if now.timeIntervalSince(status.since) > 8 {
                return "Агент ещё не ответил — возможно, ждёт подтверждения в терминале (например, доверия к папке)."
            }
            return nil
        case .working:
            // The terminal right below already shows what the agent is doing.
            return nil
        default:
            return status.message
        }
    }
}

struct MessageLine: View {
    let text: String
    let activity: SessionActivity

    /// One paragraph of plain text: newlines collapsed, the most common markdown markers removed.
    static func compact(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = t.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("#") ? String($0.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return t
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: activity.needsAttention ? activity.symbol : "text.bubble")
                .foregroundStyle(activity.needsAttention ? activity.color : .secondary)
            Text(Self.compact(text))
                .lineLimit(activity.needsAttention ? 3 : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(activity.needsAttention ? activity.color.opacity(0.15) : Color.secondary.opacity(0.08))
        .help(text)
    }
}

struct ExitedOverlay: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "stop.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Процесс агента завершён").font(.headline).foregroundStyle(.white)
            HStack {
                Button("Перезапустить") { model.relaunch(record) }
                    .buttonStyle(.glassProminent)
                Button("Закрыть сессию") { model.stopSession(record.id) }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DropHint: View {
    let accepts: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill((accepts ? Color.accentColor : Color.red).opacity(0.18))
            RoundedRectangle(cornerRadius: 10).strokeBorder(accepts ? Color.accentColor : Color.red, lineWidth: 3)
            Label(accepts ? "Запустить задачу в этой сессии" : "Сессия занята — перетащите на «+»",
                  systemImage: accepts ? "arrow.down.doc" : "nosign")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
        }
        .allowsHitTesting(false)
    }
}

/// Expand / stop for a session card: a small floating glass group, shown on hover or focus.
private struct CardControls: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    let expanded: Bool

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                Button { model.toggleExpanded(record.id) } label: {
                    Label(expanded ? "Свернуть" : "Развернуть",
                          systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(expanded ? "Свернуть (⌘↩)" : "Развернуть (⌘↩)")
                Button { model.sessionToStop = record } label: { Label("Остановить сессию", systemImage: "stop.fill") }
                    .help("Остановить сессию (⌘.)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}
