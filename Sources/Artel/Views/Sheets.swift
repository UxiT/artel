import ArtelCore
import SwiftUI

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingProject
    @State private var text = ""
    @State private var initGit = false

    private var notGit: Bool { pending.issues.contains(.notAGitRepository) }
    private var missingClaudeMD: Bool { pending.issues.contains(.missingClaudeMD) }
    /// CLAUDE.md is missing or has no description: the sheet offers to fill it, adding without it is allowed too.
    private var offersClaudeMD: Bool { missingClaudeMD || pending.issues.contains(.emptyClaudeMD) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Project “\(pending.url.lastPathComponent)”").font(.title3.bold())
            Text(pending.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

            if notGit {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Run `git init`", isOn: $initGit)
                        Text("The folder isn't a git repository. Without git, tasks run directly in the project folder: separate worktrees and change review are unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if offersClaudeMD {
                Text(missingClaudeMD
                     ? "The project has no CLAUDE.md — Claude Code reads it in every session. Fill in a description or add the project without it: you can create the file later in the Projects section."
                     : "CLAUDE.md is empty. Fill in a project description or add the project as is.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                MarkdownEditor(text: $text)
            }
            HStack {
                if offersClaudeMD && !ProjectValidator.hasDescription(text) {
                    Label("Add a description to save CLAUDE.md", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { model.pendingProject = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                if offersClaudeMD {
                    Button(missingClaudeMD ? "Add Without CLAUDE.md" : "Add As Is") {
                        model.completePendingProject(pending, claudeMD: nil, initGit: initGit)
                    }
                    Button("Save and Add") {
                        model.completePendingProject(pending, claudeMD: text, initGit: initGit)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ProjectValidator.hasDescription(text))
                } else {
                    Button("Add") {
                        model.completePendingProject(pending, claudeMD: nil, initGit: initGit)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: offersClaudeMD ? 720 : 520, height: offersClaudeMD ? 620 : nil)
        .onAppear { text = pending.claudeMD }
    }
}

/// Bordered markdown source editor for forms and sheets.
struct MarkdownEditor: View {
    @Binding var text: String

    var body: some View {
        MarkdownTextEditor(text: $text)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewSessionRequest
    @State private var projectID: UUID?
    @State private var name = ""
    @State private var agentID = ClaudeCodeAgent.id
    @State private var model_: String?
    @State private var customModel = ""
    @State private var permissionMode = "auto"
    @State private var prompt = ""
    @State private var archivesNoTask = true

    private let customTag = "__custom__"

    /// Models of the selected agent; custom ids stay free-form.
    private var agent: any CodingAgent { CodingAgents.agent(forID: agentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session").font(.title3.bold())
            Form {
                Picker("Project", selection: $projectID) {
                    ForEach(model.state.projects) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                TextField("Name", text: $name)
                Picker("Agent", selection: $agentID) {
                    ForEach(model.enabledAgents, id: \.agentID) { agent in
                        Text(agent.displayName).tag(agent.agentID)
                    }
                }
                Picker("Model", selection: $model_) {
                    ForEach(agent.models) { m in Text(m.title).tag(m.id) }
                    Text("Other…").tag(Optional(customTag))
                }
                if model_ == customTag {
                    TextField("Model ID", text: $customModel, prompt: Text(agent.agentID == KimiCodeAgent.id
                            ? "e.g. kimi-code/k3" : "e.g. claude-opus-5-5"))
                }
                Picker("Permissions", selection: $permissionMode) {
                    ForEach(agent.permissionModes, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Save to the no-task archive", isOn: $archivesNoTask)
                    .help("Copies of the hook log and the agent transcript in .artel/no-task/, so you can review the session later or add it to the board. Kept for 7 days.")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: agentID) { _, _ in applyAgentDefaults() }

            Text("First prompt (optional)").font(.callout)
            MarkdownEditor(text: $prompt).frame(minHeight: 120)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Launch") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectID == nil || (model_ == customTag && customModel.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            projectID = request.projectID ?? model.state.projects.first?.id
            agentID = model.state.settings.effectiveDefaultAgentID
            archivesNoTask = model.state.settings.archiveNoTaskSessions
            applyProjectDefaults()
        }
        .onChange(of: projectID) { _, _ in applyProjectDefaults() }
    }

    private func applyAgentDefaults() {
        // Switching agents: the model and mode lists differ, so reset the selection.
        permissionMode = agent.permissionModes.contains(permissionMode) ? permissionMode
            : (agent.permissionModes.first ?? "auto")
        let preset = projectID.flatMap({ model.project($0) })?.defaultModel
            ?? model.state.settings.defaultModel(for: agentID)
        applyPreset(preset)
    }

    private func applyProjectDefaults() {
        guard let p = projectID.flatMap({ model.project($0) }) else { return }
        name = model.nextSessionName(for: p)
        permissionMode = agent.permissionModes.contains(p.permissionMode) ? p.permissionMode
            : (agent.permissionModes.first ?? "auto")
        applyPreset(p.defaultModel ?? model.state.settings.defaultModel(for: agentID))
    }

    private func applyPreset(_ preset: String?) {
        if let preset, !agent.models.contains(where: { $0.id == preset }) {
            model_ = customTag
            customModel = preset
        } else {
            model_ = preset
        }
    }

    private func start() {
        guard let p = projectID.flatMap({ model.project($0) }) else { return }
        let chosen = model_ == customTag ? customModel.trimmingCharacters(in: .whitespaces) : model_
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        model.startSession(project: p, name: trimmedName.isEmpty ? model.nextSessionName(for: p) : trimmedName,
                           model: chosen, permissionMode: permissionMode,
                           prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), agentID: agentID,
                           archivesNoTask: archivesNoTask)
        dismiss()
    }
}

struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Settings").font(.title3.bold())
            Form {
                TextField("Name", text: $project.name)
                LabeledContent("Folder") { Text(project.path).textSelection(.enabled).foregroundStyle(.secondary) }
                LabeledContent("Color") {
                    ColorSwatches(selection: $project.colorIndex)
                }
                Picker("Permission Mode", selection: $project.permissionMode) {
                    ForEach(model.agent.permissionModes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Default Model", selection: $project.defaultModel) {
                    ForEach(model.agent.models) { m in Text(m.title).tag(m.id) }
                }
                TextField("Task Prefix", text: $project.taskPrefix)
                if project.isGitRepository {
                    TextField("Base Branch", text: Binding(get: { project.baseBranch ?? "" },
                                                             set: { project.baseBranch = $0.isEmpty ? nil : $0 }),
                              prompt: Text("current repository branch"))
                }
                EditorSettingRow(editorPath: $project.editorPath)
                DocsFolderRow(project: $project)
                if project.isGitRepository {
                    Toggle("Keep .artel/ in git", isOn: $project.storeArtelInGit)
                        .help("When off, .artel/ is added to the project's .gitignore")
                } else {
                    LabeledContent("Git") {
                        Text("not a repository: tasks run in the project folder, without worktrees or diffs")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Documentation…") {
                    dismiss()
                    model.openProjectDocs(project.id, path: nil)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    project.name = project.name.trimmingCharacters(in: .whitespaces)
                    project.taskPrefix = project.taskPrefix.trimmingCharacters(in: .whitespaces).uppercased()
                    if project.taskPrefix.isEmpty { project.taskPrefix = "ARTEL" }
                    if !project.name.isEmpty { model.updateProject(project) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: InstallRequest
    @State private var exitCode: Int32?
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title3.bold())
            Text(request.command).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            CommandTerminal(command: request.command, environment: model.loginEnvironment) { code in
                exitCode = code
                finished = true
            }
            .frame(minHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                if finished {
                    Label(exitCode == 0 ? "Done" : "Exited with code \(exitCode.map(String.init) ?? "?")",
                          systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Close" : "Stop") {
                    dismiss()
                    Task { await model.recheckTools() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
    }
}

/// Project colour: a row of swatches, the chosen one ringed. Names are read by VoiceOver.
struct ColorSwatches: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<ProjectPalette.swatches.count, id: \.self) { i in
                let chosen = ProjectPalette.index(selection) == i
                Button { selection = i } label: {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ProjectPalette.color(i).gradient)
                        .frame(width: 20, height: 20)
                        .padding(2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(chosen ? Color.primary : .clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .help(ProjectPalette.name(i))
                .accessibilityLabel(ProjectPalette.name(i))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// Project settings: where the project's documentation lives. Stored in Artel's state only, never in the project.
private struct DocsFolderRow: View {
    @Binding var project: Project

    var body: some View {
        let detected = DocsSite.detect(root: project.url)
        LabeledContent("Documentation") {
            HStack {
                TextField("", text: Binding(get: { project.docsFolder ?? "" },
                                            set: { project.docsFolder = $0.isEmpty ? nil : DocsSite.normalizeFolder($0, root: project.url) ?? project.docsFolder }),
                          prompt: Text(detected.map { "\($0) (detected)" } ?? "docs"))
                    .font(.body.monospaced())
                Button("Choose…") { choose() }
            }
        }
        .help("The folder with documentation pages inside the project. Leave empty to detect it automatically (docs/, documentation/, website/docs). Stored only in Artel's settings on this Mac.")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = project.url
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url, let folder = DocsSite.normalizeFolder(url.path, root: project.url) {
            project.docsFolder = folder
        }
    }
}
