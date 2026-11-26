import ArtelCore
import SwiftUI

/// Settings → "Fonts": family and size for each kind of text area.
struct FontSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            FontRow(title: "Session Terminal", note: "Agent sessions and setup windows.",
                    choice: $model.state.settings.fonts.terminal, monospaced: true,
                    defaultSize: FontSettings.defaults.terminal.size)
            FontRow(title: "Text Editor", note: "Task text, prompts, project documents, templates.",
                    choice: $model.state.settings.fonts.editor, monospaced: false,
                    defaultSize: FontSettings.defaults.editor.size)
            FontRow(title: "Markdown Preview", note: "Preview mode and agent replies in the history.",
                    choice: $model.state.settings.fonts.preview, monospaced: false,
                    defaultSize: FontSettings.defaults.preview.size)
            FontRow(title: "Code and Files", note: "Diffs and file contents; the family is also used for code in the editor and preview.",
                    choice: $model.state.settings.fonts.code, monospaced: true,
                    defaultSize: FontSettings.defaults.code.size)
            Section {
                Button("Reset All Fonts") { model.state.settings.fonts = FontSettings() }
                    .disabled(model.state.settings.fonts == FontSettings())
            }
        }
        .formStyle(.grouped)
    }
}

private struct FontRow: View {
    let title: String
    let note: String
    @Binding var choice: FontChoice
    let monospaced: Bool
    let defaultSize: Double

    private var families: [String] { monospaced ? FontFamilies.monospaced : FontFamilies.all }

    var body: some View {
        Section {
            Picker("Font", selection: $choice.family) {
                Text(monospaced ? "System Monospaced" : "System").tag(String?.none)
                Divider()
                // Keep a family that is no longer installed selectable, so the picker isn't blank.
                if let f = choice.family, !families.contains(f) {
                    Text("\(f) (not installed)").tag(Optional(f))
                }
                ForEach(families, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Stepper(value: $choice.size, in: FontChoice.sizeRange, step: 1) {
                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(Int(choice.size)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(monospaced ? "Claude Code ⌥ Kimi — 0123 {}[]" : "The quick brown fox jumps over the lazy dog")
                .font(choice.font(monospaced: monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Font sample")
        } header: {
            HStack {
                Text(title)
                Spacer()
                if choice != FontChoice(size: defaultSize) {
                    Button("Default") { choice = FontChoice(size: defaultSize) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
