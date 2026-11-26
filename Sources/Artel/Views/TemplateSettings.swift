import ArtelCore
import SwiftUI

struct TemplateSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var which = Which.prompt
    @State private var preview = false

    enum Which: String, CaseIterable, Identifiable {
        case prompt = "Agent Prompt"
        case task = "New Task"
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
            Text("The first message sent to the agent when a task launches.")
                .font(.caption).foregroundStyle(.secondary)
            MarkdownEditor(text: frameBinding).frame(minHeight: 260)
            if !missing.isEmpty {
                Label("\(missing.map { "{{\($0)}}" }.joined(separator: ", ")) is missing — the agent won't get the task text.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Placeholders") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PromptTemplate.frameKeys, id: \.key) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text("{{\(item.key)}}").font(.caption.monospaced()).textSelection(.enabled)
                                .frame(width: 170, alignment: .leading)
                            Text(item.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("{{#key}}…{{/key}} — the block is included in the prompt only if the value isn't empty (e.g. {{#worktree}}).")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(.top, 4)
            }
            .font(.callout)
            HStack {
                Button("Preview…") { preview = true }
                Spacer()
                Button("Reset to Default") { model.state.settings.promptFrame = nil }
                    .disabled(model.state.settings.promptFrame == nil)
            }
        }
    }

    private var taskEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The text every new task starts with.").font(.caption).foregroundStyle(.secondary)
            MarkdownEditor(text: taskBinding).frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Reset to Default") { model.state.settings.taskTemplate = nil }
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
                Text("Preview — \(task.taskID)").font(.headline)
                Spacer()
                Toggle("With worktree", isOn: $withWorktree).toggleStyle(.checkbox)
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
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
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
        let p = model.state.projects.first ?? Project(name: "example", path: "/tmp/example")
        var t = ArtelTask(projectID: p.id, directory: p.url.appendingPathComponent(".artel/tasks/\(p.taskPrefix)-1-primer"),
                         taskID: "\(p.taskPrefix)-1", title: "Example task", body: ArtelTask.bodyTemplate())
        t.branch = WorktreeLayout.branch(for: t)
        return (t, p)
    }
}
