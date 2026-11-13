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
            Text("Добавление проекта «\(pending.url.lastPathComponent)»").font(.title3.bold())
            Text(pending.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

            if notGit {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Выполнить `git init`", isOn: $initGit)
                        Text("Папка не git-репозиторий. Без git задачи работают прямо в папке проекта: отдельный worktree и просмотр изменений недоступны.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if offersClaudeMD {
                Text(missingClaudeMD
                     ? "В проекте нет CLAUDE.md — Claude Code читает его в каждой сессии. Заполните описание или добавьте проект без него: создать файл можно позже в разделе «Проекты»."
                     : "CLAUDE.md пустой. Заполните описание проекта или добавьте проект как есть.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                MarkdownEditor(text: $text)
            }
            HStack {
                if offersClaudeMD && !ProjectValidator.hasDescription(text) {
                    Label("Чтобы сохранить CLAUDE.md, добавьте текст описания", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Отмена") { model.pendingProject = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                if offersClaudeMD {
                    Button(missingClaudeMD ? "Добавить без CLAUDE.md" : "Добавить как есть") {
                        model.completePendingProject(pending, claudeMD: nil, initGit: initGit)
                    }
                    Button("Сохранить и добавить") {
                        model.completePendingProject(pending, claudeMD: text, initGit: initGit)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ProjectValidator.hasDescription(text))
                } else {
                    Button("Добавить") {
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

    private let customTag = "__custom__"

    /// Models of the selected agent; custom ids stay free-form.
    private var agent: any CodingAgent { CodingAgents.agent(forID: agentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новая сессия").font(.title3.bold())
            Form {
                Picker("Проект", selection: $projectID) {
                    ForEach(model.state.projects) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                TextField("Название", text: $name)
                Picker("Агент", selection: $agentID) {
                    ForEach(model.enabledAgents, id: \.agentID) { agent in
                        Text(agent.displayName).tag(agent.agentID)
                    }
                }
                Picker("Модель", selection: $model_) {
                    ForEach(agent.models) { m in Text(m.title).tag(m.id) }
                    Text("Другая…").tag(Optional(customTag))
                }
                if model_ == customTag {
                    TextField("Id модели", text: $customModel, prompt: Text(agent.agentID == KimiCodeAgent.id
                            ? "например, kimi-code/k3" : "например, claude-opus-5-5"))
                }
                Picker("Разрешения", selection: $permissionMode) {
                    ForEach(agent.permissionModes, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: agentID) { _, _ in applyAgentDefaults() }

            Text("Первый промпт (необязательно)").font(.callout)
            MarkdownEditor(text: $prompt).frame(minHeight: 120)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Запустить") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectID == nil || (model_ == customTag && customModel.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            projectID = request.projectID ?? model.state.projects.first?.id
            agentID = model.state.settings.effectiveDefaultAgentID
            applyProjectDefaults()
        }
        .onChange(of: projectID) { _, _ in applyProjectDefaults() }
    }

    private func applyAgentDefaults() {
        // Переход на другого агента: списки моделей и режимов другие — сбрасываем выбор.
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
                           prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), agentID: agentID)
        dismiss()
    }
}

struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Настройки проекта").font(.title3.bold())
            Form {
                TextField("Название", text: $project.name)
                LabeledContent("Папка") { Text(project.path).textSelection(.enabled).foregroundStyle(.secondary) }
                LabeledContent("Цвет") {
                    ColorSwatches(selection: $project.colorIndex)
                }
                Picker("Режим разрешений", selection: $project.permissionMode) {
                    ForEach(model.agent.permissionModes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Модель по умолчанию", selection: $project.defaultModel) {
                    ForEach(model.agent.models) { m in Text(m.title).tag(m.id) }
                }
                TextField("Префикс задач", text: $project.taskPrefix)
                if project.isGitRepository {
                    TextField("Базовая ветка", text: Binding(get: { project.baseBranch ?? "" },
                                                             set: { project.baseBranch = $0.isEmpty ? nil : $0 }),
                              prompt: Text("текущая ветка репозитория"))
                }
                EditorSettingRow(editorPath: $project.editorPath)
                if project.isGitRepository {
                    Toggle("Хранить .artel/ в git", isOn: $project.storeArtelInGit)
                        .help("Выключено — .artel/ добавляется в .gitignore проекта")
                } else {
                    LabeledContent("Git") {
                        Text("не репозиторий: задачи работают в папке проекта, без worktree и diff")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Описание и спеки…") {
                    dismiss()
                    model.openProjectDocs(project.id)
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
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
                    Label(exitCode == 0 ? "Готово" : "Завершено с кодом \(exitCode.map(String.init) ?? "?")",
                          systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Выполняется…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Закрыть" : "Прервать") {
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
