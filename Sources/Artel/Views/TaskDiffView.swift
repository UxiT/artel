import ArtelCore
import AppKit
import SwiftUI

/// Changes of the task branch vs. base, including uncommitted and new files.
struct TaskDiffView: View {
    @Environment(AppModel.self) private var model
    let task: ArtelTask
    @State private var files: [FileDiff] = []
    @State private var error: String?
    @State private var loading = true
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { f in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(f.path) },
                                                            set: { if $0 { expanded.insert(f.path) } else { expanded.remove(f.path) } })) {
                            PatchText(patch: f.patch)
                        } label: {
                            HStack(spacing: 6) {
                                Text(kindLetter(f.kind)).font(.caption.monospaced().bold()).foregroundStyle(kindColor(f.kind))
                                Text(f.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("+\(f.additions)").font(.caption.monospaced()).foregroundStyle(.green)
                                Text("−\(f.deletions)").font(.caption.monospaced()).foregroundStyle(.red)
                                if f.kind != .deleted, let wt = task.worktree {
                                    Button { model.openInEditor(projectID: task.projectID, root: URL(fileURLWithPath: wt),
                                                                files: [URL(fileURLWithPath: wt).appendingPathComponent(f.path)]) } label: {
                                        Label("Open in Code Editor", systemImage: "arrow.up.forward.square").labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Open in code editor")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .task { await load() }
    }

    private var summary: String {
        guard task.worktree != nil else { return "The task has no worktree yet" }
        if files.isEmpty && !loading { return "No changes" }
        let add = files.reduce(0) { $0 + $1.additions }, del = files.reduce(0) { $0 + $1.deletions }
        return "\(files.count) \(files.count == 1 ? "file" : "files") · +\(add) −\(del)"
    }

    private func load() async {
        guard let git = model.git, let wt = task.worktree, let project = model.project(task.projectID),
              FileManager.default.fileExists(atPath: wt) else {
            loading = false
            return
        }
        loading = true
        let base = model.baseBranch(for: project)
        let result: Result<[FileDiff], Error> = await Task.detached { Result { try git.taskDiff(worktree: wt, base: base) } }.value
        loading = false
        switch result {
        case .success(let f):
            files = f
            error = nil
            if expanded.isEmpty, f.count <= 3 { expanded = Set(f.map(\.path)) }
        case .failure(let e): error = e.localizedDescription
        }
    }

    private func kindLetter(_ k: FileDiff.Kind) -> String {
        switch k { case .added: "A"; case .modified: "M"; case .deleted: "D"; case .renamed: "R" }
    }

    private func kindColor(_ k: FileDiff.Kind) -> Color {
        switch k { case .added: .green; case .modified: .orange; case .deleted: .red; case .renamed: .blue }
    }
}

struct PatchText: View {
    let patch: String

    var body: some View {
        // Skip the git header lines; show hunks with +/- colouring.
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { !$0.hasPrefix("@@") }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : String(line))
                    .font(AppFonts.shared.settings.code.font(monospaced: true))
                    .foregroundStyle(color(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line))
            }
        }
        .textSelection(.enabled)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func color(_ l: Substring) -> Color {
        if l.hasPrefix("@@") { return .blue }
        return .primary
    }

    private func background(_ l: Substring) -> Color {
        if l.hasPrefix("+") { return .green.opacity(0.15) }
        if l.hasPrefix("-") { return .red.opacity(0.15) }
        return .clear
    }
}
