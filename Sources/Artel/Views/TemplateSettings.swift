import ArtelCore
import SwiftUI

struct TemplateSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var which = Which.prompt
    @State private var preview = false

    enum Which: String, CaseIterable, Identifiable {
        case prompt = "Промпт агента"
        case task = "Новая задача"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $which) {
                ForEach(Which.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch which {
            case .prompt: promptEditor
            case .task: taskEditor
            }
        }
        .frame(minHeight: 520)
        .sheet(isPresented: $preview) { PromptPreview(frame: frameBinding.wrappedValue) }
    }

    private var frameBinding: Binding<String> {
        Binding(get: { model.state.settings.promptFrame ?? PromptTemplate.defaultFrame },
                set: { model.state.settings.promptFrame = $0 == PromptTemplate.defaultFrame ? nil : $0 })
    }

    private var taskBinding: Binding<String> {
        Binding(get: { model.state.settings.taskTemplate ?? ArtelTask.bodyTemplate() },
                set: { model.state.settings.taskTemplate = $0 == ArtelTask.bodyTemplate() ? nil : $0 })
    }

    private var promptEditor: some View {
        let frame = frameBinding.wrappedValue
        let missing = ["task_body"].filter { !frame.contains("{{\($0)}}") }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Первое сообщение агенту при запуске задачи.")
                .font(.caption).foregroundStyle(.secondary)
            MarkdownEditor(text: frameBinding).frame(minHeight: 260)
            if !missing.isEmpty {
                Label("Нет \(missing.map { "{{\($0)}}" }.joined(separator: ", ")) — агент не получит текст задачи.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Плейсхолдеры") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PromptTemplate.frameKeys, id: \.key) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text("{{\(item.key)}}").font(.caption.monospaced()).textSelection(.enabled)
                                .frame(width: 170, alignment: .leading)
                            Text(item.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("{{#ключ}}…{{/ключ}} — блок попадёт в промпт, только если значение не пустое (например, {{#worktree}}).")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(.top, 4)
            }
            .font(.callout)
            HStack {
                Button("Предпросмотр…") { preview = true }
                Spacer()
                Button("Сбросить по умолчанию") { model.state.settings.promptFrame = nil }
                    .disabled(model.state.settings.promptFrame == nil)
            }
        }
    }

    private var taskEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Текст, с которого начинается каждая новая задача.").font(.caption).foregroundStyle(.secondary)
            MarkdownEditor(text: taskBinding).frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Сбросить по умолчанию") { model.state.settings.taskTemplate = nil }
                    .disabled(model.state.settings.taskTemplate == nil)
            }
        }
    }
}

/// The frame rendered for the selected task (or a sample one).
struct PromptPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let frame: String
    @State private var withWorktree = false

    var body: some View {
        let (task, project) = sample
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Предпросмотр — \(task.taskID)").font(.headline)
                Spacer()
                Toggle("С worktree", isOn: $withWorktree).toggleStyle(.checkbox)
            }
            ScrollView {
                Text(TaskPrompt.build(task: task, project: project,
                                      worktree: withWorktree ? (task.worktree ?? "/…/worktrees/\(task.taskID)") : nil,
                                      frame: frame))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack { Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }

    private var sample: (ArtelTask, Project) {
        if let t = model.selectedTask, let p = model.project(t.projectID) {
            var task = t
            if task.branch == nil { task.branch = WorktreeLayout.branch(for: t) }
            return (task, p)
        }
        let p = model.state.projects.first ?? Project(name: "пример", path: "/tmp/пример")
        var t = ArtelTask(projectID: p.id, directory: p.url.appendingPathComponent(".artel/tasks/\(p.taskPrefix)-1-primer"),
                         taskID: "\(p.taskPrefix)-1", title: "Пример задачи", body: ArtelTask.bodyTemplate())
        t.branch = WorktreeLayout.branch(for: t)
        return (t, p)
    }
}
