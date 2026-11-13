import ArtelCore
import SwiftUI

/// Settings → «Шрифты»: family and size for each kind of text area.
struct FontSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            FontRow(title: "Терминал сессий", note: "Сессии агентов и окна установки.",
                    choice: $model.state.settings.fonts.terminal, monospaced: true,
                    defaultSize: FontSettings.defaults.terminal.size)
            FontRow(title: "Редактор текста", note: "Текст задач, промпты, документы проекта, шаблоны.",
                    choice: $model.state.settings.fonts.editor, monospaced: false,
                    defaultSize: FontSettings.defaults.editor.size)
            FontRow(title: "Просмотр markdown", note: "Режим «Просмотр» и ответы агента в истории.",
                    choice: $model.state.settings.fonts.preview, monospaced: false,
                    defaultSize: FontSettings.defaults.preview.size)
            FontRow(title: "Код и файлы", note: "Изменения (diff), содержимое файлов; семейство — также для кода в редакторе и просмотре.",
                    choice: $model.state.settings.fonts.code, monospaced: true,
                    defaultSize: FontSettings.defaults.code.size)
            Section {
                Button("Сбросить все шрифты") { model.state.settings.fonts = FontSettings() }
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
            Picker("Шрифт", selection: $choice.family) {
                Text(monospaced ? "Системный моноширинный" : "Системный").tag(String?.none)
                Divider()
                // Keep a family that is no longer installed selectable, so the picker isn't blank.
                if let f = choice.family, !families.contains(f) {
                    Text("\(f) (не установлен)").tag(Optional(f))
                }
                ForEach(families, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Stepper(value: $choice.size, in: FontChoice.sizeRange, step: 1) {
                HStack {
                    Text("Размер")
                    Spacer()
                    Text("\(Int(choice.size)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(monospaced ? "Claude Code ⌥ Kimi — 0123 {}[]" : "Съешь же ещё этих мягких французских булок")
                .font(choice.font(monospaced: monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Пример шрифта")
        } header: {
            HStack {
                Text(title)
                Spacer()
                if choice != FontChoice(size: defaultSize) {
                    Button("По умолчанию") { choice = FontChoice(size: defaultSize) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
