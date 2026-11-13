import Foundation

/// Tiny template language for prompt frames:
/// `{{key}}` — value; `{{#key}}…{{/key}}` — block kept only when the value is non-empty.
/// Unknown keys render as empty. Runs of 3+ newlines left by removed blocks collapse to one blank line.
public enum PromptTemplate {
    public static func render(_ template: String, _ values: [String: String]) -> String {
        var text = template
        // Conditional blocks (non-nested; the same key may appear several times).
        while let open = text.range(of: #"\{\{#([a-z_]+)\}\}"#, options: .regularExpression) {
            let key = String(text[open].dropFirst(3).dropLast(2))
            guard let close = text.range(of: "{{/\(key)}}", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open)  // unbalanced: drop the stray tag
                continue
            }
            let inner = String(text[open.upperBound..<close.lowerBound])
            let keep = !(values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: keep ? inner : "")
        }
        // Values.
        var out = ""
        var rest = text[...]
        while let start = rest.range(of: "{{") {
            out += rest[..<start.lowerBound]
            guard let end = rest.range(of: "}}", range: start.upperBound..<rest.endIndex) else {
                out += rest[start.lowerBound...]
                rest = ""
                break
            }
            let key = rest[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            out += values[key] ?? ""
            rest = rest[end.upperBound...]
        }
        out += rest
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Placeholders available in the prompt frame, with descriptions for the settings screen.
    public static let frameKeys: [(key: String, description: String)] = [
        ("task_id", "id задачи, например ARTEL-12"),
        ("title", "заголовок задачи"),
        ("project", "имя проекта"),
        ("worktree", "путь к worktree задачи (пусто, если задача идёт в проекте)"),
        ("branch", "ветка worktree задачи"),
        ("task_dir", "папка задачи (task.md, attachments/)"),
        ("task_body", "текст задачи"),
    ]

    /// Default frame; reproduces Artel's built-in prompt.
    public static let defaultFrame = """
    Задача {{task_id}} «{{title}}» проекта {{project}}.
    {{#worktree}}Рабочая директория — git worktree задачи ({{worktree}}, ветка {{branch}}). Код меняй только здесь.{{/worktree}}
    Файлы задачи (вложения) лежат в {{task_dir}}; task.md не правь.

    {{task_body}}
    """

    /// Keys of the removed plan/review workflow. A saved frame that uses them was written for
    /// aide-mcp tools that no longer exist.
    public static let obsoleteKeys = ["base", "iteration", "stage", "reason", "stage_instructions"]

    public static func isObsolete(_ frame: String) -> Bool {
        obsoleteKeys.contains { frame.contains("{{\($0)}}") || frame.contains("{{#\($0)}}") } || frame.contains("mcp__aide")
    }
}
