import ArtelCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// The last opened tab, as macOS settings windows usually remember it.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }.tag("notifications")
            FontSettingsView().tabItem { Label("Fonts", systemImage: "textformat.size") }.tag("fonts")
            LimitsSettingsView().tabItem { Label("Limits", systemImage: "gauge.with.dots.needle.50percent") }.tag("limits")
            TemplateSettingsView().tabItem { Label("Templates", systemImage: "text.badge.star") }.tag("templates")
        }
        .scenePadding(.minimum)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Tools") {
                toolRow("claude", detected: model.claudePath, version: model.claudeVersion,
                        override: Binding(get: { model.state.settings.claudePath ?? "" },
                                          set: { model.state.settings.claudePath = $0.isEmpty ? nil : $0 }))
                toolRow("kimi", detected: model.kimiPath, version: model.kimiVersion,
                        override: Binding(get: { model.state.settings.kimiPath ?? "" },
                                          set: { model.state.settings.kimiPath = $0.isEmpty ? nil : $0 }))
                toolRow("tmux", detected: model.tmuxPath.map { $0 + (model.usingBundledTmux ? " (built-in)" : "") },
                        version: model.tmuxVersion,
                        override: Binding(get: { model.state.settings.tmuxPath ?? "" },
                                          set: { model.state.settings.tmuxPath = $0.isEmpty ? nil : $0 }))
                Toggle("Use built-in tmux", isOn: $model.state.settings.preferBundledTmux)
                    .help("The built-in tmux is used automatically if tmux isn't found on the system. The change applies to a new tmux server: stop all sessions or restart your Mac.")
                Button("Check Again") { Task { await model.recheckTools() } }
            }
            Section {
                ForEach(model.agents, id: \.agentID) { agent in
                    let enabled = model.state.settings.isAgentEnabled(agent.agentID)
                    LabeledContent {
                        Picker("Default Model", selection: Binding(
                            get: { model.state.settings.defaultModels[agent.agentID] ?? nil },
                            set: { model.state.settings.defaultModels[agent.agentID] = $0 })) {
                            ForEach(agent.models) { m in Text(m.title).tag(m.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!enabled)
                        .help("Default model for \(agent.displayName)")
                    } label: {
                        Toggle(agent.displayName, isOn: Binding(
                            get: { enabled },
                            set: { model.state.settings.setAgentEnabled(agent.agentID, $0) }))
                            .toggleStyle(.checkbox)
                            // The last enabled agent cannot be turned off.
                            .disabled(enabled && model.state.settings.enabledAgentIDs.count == 1)
                    }
                }
                Picker("Default Agent", selection: Binding(
                    get: { model.state.settings.effectiveDefaultAgentID },
                    set: { model.state.settings.defaultAgentID = $0 == ClaudeCodeAgent.id ? nil : $0 })) {
                    ForEach(model.enabledAgents, id: \.agentID) { agent in
                        Text(agent.displayName).tag(agent.agentID)
                    }
                }
            } header: {
                Text("AI Agents")
            } footer: {
                Text("The default model for each agent is on the right. A disabled agent isn't offered for new sessions and tasks, and its limits aren't shown. Sessions that are already running keep working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Session Grid") {
                Toggle("Show sessions waiting for you first", isOn: $model.state.settings.waitingFirst)
            }
            Section {
                Toggle("Archive sessions without a task", isOn: $model.state.settings.archiveNoTaskSessions)
            } header: {
                Text("Sessions Without a Task")
            } footer: {
                Text("The default for new sessions; you can change it in the New Session window and in the card menu. The archive holds copies of the hook log and the agent transcript in the project's .artel/no-task/ and is kept for 7 days. Without it, a session can't be reopened after closing or added to the board.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ExcalidrawAddonRow()
            } header: {
                Text("Documentation")
            } footer: {
                Text("Excalidraw's own editor and renderer (@excalidraw/excalidraw \(ExcalidrawAddon.version), MIT) with its fonts: draw .excalidraw diagrams right in the documentation and see them exactly as in Excalidraw. Downloaded once (~\(ExcalidrawAddon.sizeMB) MB) from Artel's GitHub releases, verified by checksum and kept in Artel's data folder. Without it, diagrams are shown by a simplified built-in renderer and can't be edited in Artel.")
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
                Text(detected.map { "\($0)  \(version ?? "")" } ?? "not found")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            DisclosureGroup("Set Path Manually") {
                TextField("Path to \(name)", text: override, prompt: Text("empty — detect automatically"))
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
            Toggle("System notifications", isOn: $model.state.settings.notifications.enabled)
            Section("Notify When") {
                Toggle("The agent asks a question or is waiting for input", isOn: $model.state.settings.notifications.waitingInput)
                Toggle("The agent is waiting for permission", isOn: $model.state.settings.notifications.waitingPermission)
                Toggle("The agent finishes", isOn: $model.state.settings.notifications.finished)
                Toggle("An error occurs", isOn: $model.state.settings.notifications.error)
            }
            .disabled(!model.state.settings.notifications.enabled)
            Section {
                Toggle("Notify even when Artel is active", isOn: $model.state.settings.notifications.whenActive)
                Toggle("Sound", isOn: $model.state.settings.notifications.sound)
            }
            .disabled(!model.state.settings.notifications.enabled)
        }
        .formStyle(.grouped)
    }
}

/// Download / remove the Excalidraw editor and renderer (ExcalidrawAddon).
struct ExcalidrawAddonRow: View {
    var compact = false
    @State private var addon = ExcalidrawAddon.shared

    var body: some View {
        switch addon.state {
        case .installed:
            if compact {
                EmptyView()
            } else {
                LabeledContent("Excalidraw") {
                    HStack {
                        Text("installed").foregroundStyle(.secondary)
                        Button("Delete") { addon.remove() }
                    }
                }
            }
        case .downloading:
            HStack(spacing: 6) {
                if !compact { Text("Excalidraw"); Spacer() }
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            }
        case .notInstalled, .failed:
            if compact {
                Button("Install Excalidraw…") { addon.install() }
                    .help("Download Excalidraw's editor and renderer (~\(ExcalidrawAddon.sizeMB) MB, once) to edit drawings here and see them exactly as in Excalidraw. Without it, drawings are shown simplified and read-only.")
            } else {
                LabeledContent("Excalidraw") {
                    HStack {
                        if case .failed(let message) = addon.state {
                            Text("Download failed: \(message)").foregroundStyle(.red).lineLimit(2)
                        } else {
                            Text("not installed — view only").foregroundStyle(.secondary)
                        }
                        Button("Download Editor (~\(ExcalidrawAddon.sizeMB) MB)") { addon.install() }
                    }
                }
            }
        }
    }
}
