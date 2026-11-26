import ArtelCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// The last opened tab, as macOS settings windows usually remember it.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("Основные", systemImage: "gearshape") }.tag("general")
            NotificationSettingsView().tabItem { Label("Уведомления", systemImage: "bell") }.tag("notifications")
            FontSettingsView().tabItem { Label("Шрифты", systemImage: "textformat.size") }.tag("fonts")
            LimitsSettingsView().tabItem { Label("Лимиты", systemImage: "gauge.with.dots.needle.50percent") }.tag("limits")
            TemplateSettingsView().tabItem { Label("Шаблоны", systemImage: "text.badge.star") }.tag("templates")
        }
        .scenePadding(.minimum)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Инструменты") {
                toolRow("claude", detected: model.claudePath, version: model.claudeVersion,
                        override: Binding(get: { model.state.settings.claudePath ?? "" },
                                          set: { model.state.settings.claudePath = $0.isEmpty ? nil : $0 }))
                toolRow("kimi", detected: model.kimiPath, version: model.kimiVersion,
                        override: Binding(get: { model.state.settings.kimiPath ?? "" },
                                          set: { model.state.settings.kimiPath = $0.isEmpty ? nil : $0 }))
                toolRow("tmux", detected: model.tmuxPath.map { $0 + (model.usingBundledTmux ? " (встроенный)" : "") },
                        version: model.tmuxVersion,
                        override: Binding(get: { model.state.settings.tmuxPath ?? "" },
                                          set: { model.state.settings.tmuxPath = $0.isEmpty ? nil : $0 }))
                Toggle("Использовать встроенный tmux", isOn: $model.state.settings.preferBundledTmux)
                    .help("Встроенный tmux используется автоматически, если в системе tmux не найден. Смена применяется к новому tmux-серверу: остановите все сессии или перезапустите Mac.")
                Button("Проверить снова") { Task { await model.recheckTools() } }
            }
            Section {
                ForEach(model.agents, id: \.agentID) { agent in
                    let enabled = model.state.settings.isAgentEnabled(agent.agentID)
                    LabeledContent {
                        Picker("Модель по умолчанию", selection: Binding(
                            get: { model.state.settings.defaultModels[agent.agentID] ?? nil },
                            set: { model.state.settings.defaultModels[agent.agentID] = $0 })) {
                            ForEach(agent.models) { m in Text(m.title).tag(m.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!enabled)
                        .help("Модель по умолчанию для \(agent.displayName)")
                    } label: {
                        Toggle(agent.displayName, isOn: Binding(
                            get: { enabled },
                            set: { model.state.settings.setAgentEnabled(agent.agentID, $0) }))
                            .toggleStyle(.checkbox)
                            // The last enabled agent cannot be turned off.
                            .disabled(enabled && model.state.settings.enabledAgentIDs.count == 1)
                    }
                }
                Picker("Агент по умолчанию", selection: Binding(
                    get: { model.state.settings.effectiveDefaultAgentID },
                    set: { model.state.settings.defaultAgentID = $0 == ClaudeCodeAgent.id ? nil : $0 })) {
                    ForEach(model.enabledAgents, id: \.agentID) { agent in
                        Text(agent.displayName).tag(agent.agentID)
                    }
                }
            } header: {
                Text("ИИ-агенты")
            } footer: {
                Text("Справа — модель по умолчанию для агента. Выключенный агент не предлагается для новых сессий и задач, его лимиты не показываются. Уже запущенные сессии продолжают работать.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Сетка сессий") {
                Toggle("Ждущие ответа — первыми в сетке", isOn: $model.state.settings.waitingFirst)
            }
            Section {
                Toggle("Сохранять сессии без задачи в архив", isOn: $model.state.settings.archiveNoTaskSessions)
            } header: {
                Text("Сессии без задачи")
            } footer: {
                Text("Значение по умолчанию для новых сессий; в окне новой сессии и в меню карточки его можно поменять. Архив — копии лога хуков и транскрипта агента в .artel/no-task/ проекта, хранится 7 дней. Без архива сессию нельзя будет открыть после закрытия или добавить на доску.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func toolRow(_ name: String, detected: String?, version: String?, override: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: detected == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(detected == nil ? .red : .green)
                Text(name).bold()
                Text(detected.map { "\($0)  \(version ?? "")" } ?? "не найден")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            DisclosureGroup("Указать путь вручную") {
                TextField("Путь к \(name)", text: override, prompt: Text("пусто — автоопределение"))
                    .font(.caption)
            }
            .font(.caption)
        }
    }
}

private struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Системные уведомления", isOn: $model.state.settings.notifications.enabled)
            Section("Когда уведомлять") {
                Toggle("Агент задал вопрос / ждёт ответа", isOn: $model.state.settings.notifications.waitingInput)
                Toggle("Агент ждёт разрешения", isOn: $model.state.settings.notifications.waitingPermission)
                Toggle("Агент завершил работу", isOn: $model.state.settings.notifications.finished)
                Toggle("Ошибка", isOn: $model.state.settings.notifications.error)
            }
            .disabled(!model.state.settings.notifications.enabled)
            Section {
                Toggle("Уведомлять, даже когда Artel активен", isOn: $model.state.settings.notifications.whenActive)
                Toggle("Звук", isOn: $model.state.settings.notifications.sound)
            }
            .disabled(!model.state.settings.notifications.enabled)
        }
        .formStyle(.grouped)
    }
}
