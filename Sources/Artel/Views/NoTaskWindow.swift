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
                .navigationSubtitle("\(project.name) · session without a task, archive kept for 7 days")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { NSWorkspace.shared.open(archive.directory) } label: {
                            Label("Archive Folder", systemImage: "folder")
                        }
                        .help("Open the archive folder in Finder")
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.convertNoTask(archive) } label: {
                            Label("Add to Board", systemImage: "plus.square.on.square").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.glassProminent)
                        .help("Create a numbered task, keeping the history and files")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Session Archive Not Found", systemImage: "archivebox")
                } description: {
                    Text("Archives of sessions without a task are kept for 7 days.")
                } actions: {
                    Button("Close Window") { dismissWindow(id: TaskWindowScene.id) }
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
                    Text("Updated \(archive.updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("First Prompt") {
                    if archive.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("The first prompt wasn't saved.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        MarkdownPreview(text: archive.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                section("What Was Done") {
                    if let reply = replies.last {
                        if replies.count > 1 {
                            Text("Agent's last reply · replies in total: \(replies.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        MarkdownPreview(text: reply)
                    } else {
                        Text("The text of the final reply wasn't saved in the agent's events. The available actions are listed below, and the full session files are on the right.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !tools.isEmpty {
                    section("Agent Actions · \(tools.count)") {
                        ForEach(Array(tools.suffix(8).enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.caption).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.toolName ?? "Tool").font(.callout.weight(.medium))
                                    if let summary = event.toolSummary {
                                        Text(summary).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(3).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if tools.count > 8 {
                            Text("Showing the last 8 actions. All events are in the JSONL file on the right.")
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
                Text("Session Files · \(files.count)").font(.headline)
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
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                Text(url?.lastPathComponent ?? "No file selected").font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if let url {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
                    }
                    .help("Show in Finder")
                }
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            if url == nil {
                Text("Select a file above").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if truncated {
                            Text("Showing the first 1 MB of the file. Open it in another app to see all of it.")
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
        content = String(data: data, encoding: .utf8) ?? "Text preview isn't available. Open the file in another app."
        // task.md of an archive: its frontmatter (status: done etc.) is bookkeeping, show the text.
        if url.lastPathComponent == "task.md", content.hasPrefix("---\n"),
           let end = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) {
            content = String(content[end.upperBound...]).trimmingCharacters(in: .newlines)
        }
    }
}
