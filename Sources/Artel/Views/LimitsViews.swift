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
                    Label("Limits", systemImage: "gauge.with.dots.needle.50percent")
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
        .help("AI subscription limits")
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
                Text("Not signed in").font(.caption).foregroundStyle(.secondary)
            case .needsLogin:
                Text("Sign in to the CLI").font(.caption).foregroundStyle(.orange)
            default:
                if state.headline.isEmpty {
                    HStack(spacing: 4) {
                        if state.status == .loading { ProgressView().controlSize(.mini) }
                        Text("Limits").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    // One line: "5h ▬ 34%   7d ▬ 5%".
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
                            .accessibilityLabel("\(w.label): \(Int(w.usedPercent.rounded()))% used")
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
                Text("AI Limits").font(.headline)
                Spacer()
                Button { usage.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            HStack(spacing: 14) {
                Text("Show:").font(.caption).foregroundStyle(.secondary)
                ForEach(usage.availableAgentIDs, id: \.self) { id in
                    Toggle(usage.state(for: id).title, isOn: visibilityBinding(id))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }
            if usage.visibleStates.isEmpty {
                Text("Select at least one agent to see its limits.")
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
                                Text("\(Int(w.usedPercent.rounded()))% used")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            ProgressView(value: w.usedPercent, total: 100).tint(w.tint)
                            if let reset = w.resetsAt {
                                Text("Resets in \(formatDuration(reset.timeIntervalSinceNow)) · \(reset.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if state.windows.isEmpty && state.status == .ok {
                        Text("The API returned no limit windows.").font(.caption).foregroundStyle(.secondary)
                    }
                    LimitStatusMessage(state: state)
                    if let at = state.updatedAt {
                        Text("Updated \(at.formatted(date: .omitted, time: .standard))")
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
                 ? "No Kimi Code login found. Run `kimi` and sign in (/login)."
                 : "No Claude Code login found. Run `claude` and sign in (/login). If macOS asked for Keychain access, click Refresh and allow it.")
                .font(.caption).foregroundStyle(.secondary)
        case .needsLogin:
            Text(state.id == KimiCodeAgent.id
                 ? "Kimi Code rejected the token. Sign in again: `kimi` → /login."
                 : "Claude Code rejected the token. Sign in again: `claude` → /login.")
                .font(.caption).foregroundStyle(.orange)
        case .error(let message):
            Text("Couldn't refresh: \(message). Showing the last data.")
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
            Toggle("Show subscription limits", isOn: $model.state.settings.limits.enabled)
            Section("Agents in the Shared Segment") {
                ForEach(model.usage.availableAgentIDs, id: \.self) { id in
                    Toggle(model.usage.state(for: id).title, isOn: visibilityBinding(id))
                        .toggleStyle(.checkbox)
                        .disabled(!model.state.settings.limits.enabled)
                }
            }
            Text("Only enabled agents are listed here; the list is set in General settings.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Artel only reads the existing Claude Code and Kimi Code logins and calls the same APIs as the CLIs. For Claude, macOS asks for Keychain access on the first request; choose Always Allow.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Refresh every", selection: $model.state.settings.limits.intervalMinutes) {
                ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
            }
            .disabled(!model.state.settings.limits.enabled)
            Toggle("Notify when a limit is nearly used up", isOn: $model.state.settings.limits.alerts)
                .disabled(!model.state.settings.limits.enabled)
            Picker("Threshold (remaining below)", selection: $model.state.settings.limits.thresholdRemaining) {
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
