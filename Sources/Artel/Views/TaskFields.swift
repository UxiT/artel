import ArtelCore
import AppKit
import SwiftUI

/// Model picker with "default" and a free-form id.
struct ModelField: View {
    @Binding var model_: String?
    let agent: any CodingAgent
    private let customTag = "__custom__"

    var body: some View {
        let known = agent.models.contains { $0.id == model_ }
        HStack {
            Picker("", selection: Binding(get: { known ? model_ : customTag }, set: { v in
                if v == customTag { if known { model_ = "" } } else { model_ = v }
            })) {
                Text("Спросить при запуске").tag(String?.none)
                ForEach(agent.models.filter { $0.id != nil }) { m in Text(m.title).tag(m.id) }
                Text("Другая…").tag(Optional(customTag))
            }
            .labelsHidden()
            if !known {
                TextField("id модели", text: Binding(get: { model_ ?? "" }, set: { model_ = $0.isEmpty ? "" : $0 }))
                    .frame(minWidth: 120)
            }
        }
    }
}

/// A labelled row of a task settings grid.
struct MetaRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            content
        }
    }
}

/// Agent and model of a task: rows for a `Grid`.
/// Shared by the task window and the new-task draft, which bind them to different storage.
struct TaskSettingsFields: View {
    @Binding var model_: String?
    @Binding var agentID: String

    /// The chosen agent: its model list drives the model field.
    private var agent: any CodingAgent { CodingAgents.agent(forID: agentID) }

    var body: some View {
        MetaRow("Агент") {
            Picker("", selection: Binding(get: { agentID }, set: { newID in
                agentID = newID
                // Модель другого агента может не существовать у нового — сбрасываем на выбор при запуске.
                if let m = model_, !CodingAgents.agent(forID: newID).models.contains(where: { $0.id == m }) {
                    model_ = nil
                }
            })) {
                ForEach(CodingAgents.all, id: \.agentID) { agent in
                    Text(agent.displayName).tag(agent.agentID)
                }
            }.labelsHidden()
        }
        MetaRow("Модель") { ModelField(model_: $model_, agent: agent) }
    }
}
