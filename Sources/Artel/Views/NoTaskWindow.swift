import ArtelCore
import AppKit
import SwiftUI

/// Read-only overview of an archived session that was started without a task.
struct NoTaskWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let archiveID: String
    @State private var events: [HookEvent] = []
    @State private var files: [URL] = []
    @State private var selectedFile: URL?

    var body: some View {
        Group {
            if let archive = model.noTask(archiveID), let project = model.project(archive.projectID) {
                VStack(spacing: 0) {
                    HSplitView {
                        overview(archive)
                            .frame(minWidth: 430, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        filesPane(archive)
                            .frame(minWidth: 360, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear { load(archive) }
                .navigationTitle(archive.title)
                .navigationSubtitle("\(project.name) · сессия без задачи, архив хранится 7 дней")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { NSWorkspace.shared.open(archive.directory) } label: {
                            Label("Папка архива", systemImage: "folder")
                        }
                        .help("Открыть папку архива в Finder")
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.convertNoTask(archive) } label: {
                            Label("Добавить на доску", systemImage: "plus.square.on.square").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.glassProminent)
                        .help("Создать номерную задачу, сохранив историю и файлы")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Архив сессии не найден", systemImage: "archivebox")
                } description: {
                    Text("Архивы сессий без задачи хранятся 7 дней.")
                } actions: {
                    Button("Закрыть окно") { dismissWindow(id: TaskWindowScene.id) }
                }
            }
        }
    }

    private func overview(_ archive: ArtelTask) -> some View {
        let replies = events.filter { $0.name == "Stop" }.compactMap { event in
            event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let tools = events.filter { $0.name == "PreToolUse" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(archive.title).font(.title2.weight(.semibold))
                    Text("Обновлено \(archive.updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Первый запрос") {
                    if archive.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Первый запрос не сохранился.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        MarkdownPreview(text: archive.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                section("Что было сделано") {
                    if let reply = replies.last {
                        if replies.count > 1 {
                            Text("Последний ответ агента · всего ответов: \(replies.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        MarkdownPreview(text: reply)
                    } else {
                        Text("Текст итогового ответа не сохранился в событиях агента. Ниже перечислены доступные действия, а справа — полные файлы сессии.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !tools.isEmpty {
                    section("Действия агента · \(tools.count)") {
                        ForEach(Array(tools.suffix(8).enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.caption).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.toolName ?? "Инструмент").font(.callout.weight(.medium))
                                    if let summary = event.toolSummary {
                                        Text(summary).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(3).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if tools.count > 8 {
                            Text("Показаны последние 8 действий. Все события — в JSONL-файле справа.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func filesPane(_ archive: ArtelTask) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Файлы сессии · \(files.count)").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            List(selection: $selectedFile) {
                ForEach(files, id: \.self) { url in
                    Label(relativePath(url, archive: archive), systemImage: "doc.text")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(url)
                        .contextMenu {
                            Button("Открыть") { NSWorkspace.shared.open(url) }
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 150, idealHeight: 220, maxHeight: 280)
            Divider()
            NoTaskFilePreview(url: selectedFile)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func load(_ archive: ArtelTask) {
        events = NoTaskStore.events(for: archive)
        files = NoTaskStore.files(for: archive)
        selectedFile = files.first { $0.lastPathComponent == "task.md" } ?? files.first
    }

    private func relativePath(_ url: URL, archive: ArtelTask) -> String {
        url.path.replacingOccurrences(of: archive.directory.path + "/", with: "")
    }
}

private struct NoTaskFilePreview: View {
    let url: URL?
    @State private var content = ""
    @State private var truncated = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url?.lastPathComponent ?? "Файл не выбран").font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if let url {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Открыть", systemImage: "arrow.up.forward.app") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Показать в Finder", systemImage: "folder").labelStyle(.iconOnly)
                    }
                    .help("Показать в Finder")
                }
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            if url == nil {
                Text("Выберите файл выше").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if truncated {
                            Text("Показан первый 1 МБ файла. Откройте файл внешним приложением, чтобы увидеть всё.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(content).font(AppFonts.shared.settings.code.font(monospaced: true)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in load() }
    }

    private func load() {
        content = ""
        truncated = false
        guard let url else { return }
        let limit = 1_000_000
        let handle = try? FileHandle(forReadingFrom: url)
        let data = handle?.readData(ofLength: limit) ?? Data()
        try? handle?.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        truncated = size > UInt64(limit)
        content = String(data: data, encoding: .utf8) ?? "Текстовый предпросмотр недоступен. Откройте файл внешним приложением."
        // task.md of an archive: its frontmatter (status: done etc.) is bookkeeping, show the text.
        if url.lastPathComponent == "task.md", content.hasPrefix("---\n"),
           let end = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) {
            content = String(content[end.upperBound...]).trimmingCharacters(in: .newlines)
        }
    }
}
