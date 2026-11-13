import Foundation

/// Which JetBrains IDE fits a project, judged by marker files in its root.
public enum JetBrainsIDE {
    /// Bundle ids of JetBrains apps that are code editors (Toolbox, DataGrip, Space… are not).
    public static let codeEditors: [String: String] = [
        "com.jetbrains.intellij": "IntelliJ IDEA",
        "com.jetbrains.intellij.ce": "IntelliJ IDEA CE",
        "com.jetbrains.goland": "GoLand",
        "com.jetbrains.rustrover": "RustRover",
        "com.jetbrains.WebStorm": "WebStorm",
        "com.jetbrains.PhpStorm": "PhpStorm",
        "com.jetbrains.pycharm": "PyCharm",
        "com.jetbrains.pycharm.ce": "PyCharm CE",
        "com.jetbrains.rubymine": "RubyMine",
        "com.jetbrains.rider": "Rider",
        "com.jetbrains.CLion": "CLion",
        "com.jetbrains.fleet": "Fleet",
    ]

    public static func isCodeEditor(_ bundleID: String) -> Bool { codeEditors[bundleID] != nil }

    /// Marker file → preferred IDEs, most specific first.
    static let markers: [(files: [String], ides: [String])] = [
        (["go.mod", "go.work"], ["com.jetbrains.goland"]),
        (["Cargo.toml"], ["com.jetbrains.rustrover", "com.jetbrains.CLion"]),
        (["composer.json"], ["com.jetbrains.PhpStorm"]),
        (["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"], ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        (["Gemfile"], ["com.jetbrains.rubymine"]),
        (["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle.kts"], ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        (["CMakeLists.txt"], ["com.jetbrains.CLion"]),
        (["package.json", "tsconfig.json", "deno.json"], ["com.jetbrains.WebStorm"]),
    ]

    /// IDEs that suit the project, in preference order. IntelliJ IDEA Ultimate goes last as the
    /// universal fallback (its plugins cover most stacks).
    public static func candidates(forProjectAt dir: URL) -> [String] {
        let fm = FileManager.default
        let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        var out: [String] = []
        for m in markers where m.files.contains(where: names.contains) {
            for ide in m.ides where !out.contains(ide) { out.append(ide) }
        }
        if names.contains(where: { $0.hasSuffix(".sln") || $0.hasSuffix(".csproj") }) { out.insert("com.jetbrains.rider", at: 0) }
        if !out.contains("com.jetbrains.intellij") { out.append("com.jetbrains.intellij") }
        return out
    }

    /// The IDE to use without asking: the first installed candidate. Nil when none of the
    /// candidates is installed — the operator chooses.
    public static func autoChoice(forProjectAt dir: URL, installed: Set<String>) -> String? {
        candidates(forProjectAt: dir).first { installed.contains($0) }
    }
}
