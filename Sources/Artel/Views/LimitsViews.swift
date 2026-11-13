import ArtelCore
import SwiftUI

extension LimitWindow {
    var tint: Color {
        remainingPercent < 15 ? .red : remainingPercent < 35 ? .orange : .green
    }
}

/// One shared status-bar segment with a compact column per visible agent.
struct LimitsIndicator: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        let usage = model.usage
        Button { showDetails.toggle() } label: {
            HStack(spacing: 0) {
                if usage.visibleStates.isEmpty {
                    // Nothing selected: keep a handle to the popover, where agents can be selected again.
                    Label("Лимиты", systemImage: "gauge.with.dots.needle.50percent")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 2)
                }
                ForEach(Array(usage.visibleStates.enumerated()), id: \.element.id) { index, state in
                    if index > 0 { Divider().padding(.horizontal, 9) }
                    LimitsHeadline(state: state)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Лимиты подписок ИИ")
        .popover(isPresented: $showDetails, arrowEdge: .top) { LimitsDetails().environment(model) }
    }
}

private struct LimitsHeadline: View {
    let state: UsageMonitor.ProviderState

    var body: some View {
        HStack(spacing: 6) {
            Label(state.compactTitle, systemImage: state.systemImage)
                .font(.caption.bold())
                .labelStyle(.titleAndIcon)
            switch state.status {
            case .noCredentials:
                Text("Нет логина").font(.caption).foregroundStyle(.secondary)
            case .needsLogin:
                Text("Войдите в CLI").font(.caption).foregroundStyle(.orange)
            default:
                if state.headline.isEmpty {
                    HStack(spacing: 4) {
                        if state.status == .loading { ProgressView().controlSize(.mini) }
                        Text("Лимиты").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    // One line: «5ч ▬ 34%   7д ▬ 5%».
                    HStack(spacing: 10) {
                        ForEach(state.headline) { w in
                            HStack(spacing: 4) {
                                Text(w.shortLabel)
                                    .font(.caption2)
                                ProgressView(value: w.usedPercent, total: 100)
                                    .progressViewStyle(.linear)
                                    .tint(w.tint)
                                    .frame(width: 36)
                                Text("\(Int(w.usedPercent.rounded()))%")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(w.label): использовано \(Int(w.usedPercent.rounded()))%")
                        }
                    }
                }
            }
            if case .error = state.status {
                Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LimitsDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.usage
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Лимиты ИИ").font(.headline)
                Spacer()
                Button { usage.refreshNow() } label: { Label("Обновить", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Обновить")
            }
            HStack(spacing: 14) {
                Text("Показывать:").font(.caption).foregroundStyle(.secondary)
                ForEach(usage.availableAgentIDs, id: \.self) { id in
                    Toggle(usage.state(for: id).title, isOn: visibilityBinding(id))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }
            if usage.visibleStates.isEmpty {
                Text("Выберите хотя бы одного агента, чтобы увидеть его лимиты.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(usage.visibleStates.enumerated()), id: \.element.id) { index, state in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(state.title, systemImage: state.systemImage).font(.headline)
                        if let plan = state.plan {
                            Text(plan).font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                        Spacer()
                    }
                    ForEach(state.windows) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(w.label)
                                Spacer()
                                Text("\(Int(w.usedPercent.rounded()))% использовано")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            ProgressView(value: w.usedPercent, total: 100).tint(w.tint)
                            if let reset = w.resetsAt {
                                Text("Сброс через \(formatDuration(reset.timeIntervalSinceNow)) · \(reset.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if state.windows.isEmpty && state.status == .ok {
                        Text("API не вернул окна лимитов.").font(.caption).foregroundStyle(.secondary)
                    }
                    LimitStatusMessage(state: state)
                    if let at = state.updatedAt {
                        Text("Обновлено \(at.formatted(date: .omitted, time: .standard))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { usage.refreshNow() }
    }

    private func visibilityBinding(_ agentID: String) -> Binding<Bool> {
        Binding(
            get: { model.state.settings.limits.shows(agentID) },
            set: { model.state.settings.limits.setVisible(agentID, $0) }
        )
    }
}

private struct LimitStatusMessage: View {
    let state: UsageMonitor.ProviderState

    var body: some View {
        switch state.status {
        case .noCredentials:
            Text(state.id == KimiCodeAgent.id
                 ? "Не найден логин Kimi Code. Запустите `kimi` и войдите (/login)."
                 : "Не найден логин Claude Code. Запустите `claude` и войдите (/login). Если macOS спрашивала доступ к связке ключей — нажмите «Обновить» и разрешите его.")
                .font(.caption).foregroundStyle(.secondary)
        case .needsLogin:
            Text(state.id == KimiCodeAgent.id
                 ? "Токен Kimi Code не принят. Войдите заново: `kimi` → /login."
                 : "Токен Claude Code не принят. Войдите заново: `claude` → /login.")
                .font(.caption).foregroundStyle(.orange)
        case .error(let message):
            Text("Не удалось обновить: \(message). Показаны последние данные.")
                .font(.caption).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

struct LimitsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Показывать лимиты подписки", isOn: $model.state.settings.limits.enabled)
            Section("Агенты в общем сегменте") {
                ForEach(model.usage.availableAgentIDs, id: \.self) { id in
                    Toggle(model.usage.state(for: id).title, isOn: visibilityBinding(id))
                        .toggleStyle(.checkbox)
                        .disabled(!model.state.settings.limits.enabled)
                }
            }
            Text("Здесь только включённые агенты — список задаётся в «Основных» настройках.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Artel только читает существующие логины Claude Code и Kimi Code и запрашивает те же API, что и CLI. Для Claude macOS при первом запросе спросит доступ к связке ключей — выберите «Разрешать всегда».")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Обновлять каждые", selection: $model.state.settings.limits.intervalMinutes) {
                ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) мин").tag($0) }
            }
            .disabled(!model.state.settings.limits.enabled)
            Toggle("Уведомлять, когда лимит почти исчерпан", isOn: $model.state.settings.limits.alerts)
                .disabled(!model.state.settings.limits.enabled)
            Picker("Порог (осталось меньше)", selection: $model.state.settings.limits.thresholdRemaining) {
                ForEach([5, 10, 15, 20, 25, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
            }
            .disabled(!model.state.settings.limits.enabled || !model.state.settings.limits.alerts)
        }
        .formStyle(.grouped)
    }

    private func visibilityBinding(_ agentID: String) -> Binding<Bool> {
        Binding(
            get: { model.state.settings.limits.shows(agentID) },
            set: { model.state.settings.limits.setVisible(agentID, $0) }
        )
    }
}
