import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// Runs a process to completion and captures its output.
    @discardableResult
    public static func run(_ executable: String, _ args: [String], environment: [String: String]? = nil,
                           cwd: String? = nil, timeout: TimeInterval = 30) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let environment { p.environment = environment }
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()

        // Read concurrently so a chatty process can't fill the pipe and deadlock.
        nonisolated(unsafe) var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        group.wait()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// The user's login-shell environment.
///
/// GUI apps start with a minimal environment (PATH without Homebrew, ~/.local/bin, nvm…).
/// Agents need the same environment the user has in Terminal, so we ask the login shell once.
public enum ShellEnvironment {
    public static func loadLoginEnvironment(timeout: TimeInterval = 8) -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__ARTEL_ENV__"
        // -l loads the login profile; -i is avoided because interactive rc files may print or block.
        if let result = try? Shell.run(shell, ["-l", "-c", "echo \(marker); /usr/bin/env -0"], timeout: timeout),
           result.ok, let range = result.stdout.range(of: marker + "\n") {
            let payload = result.stdout[range.upperBound...]
            for entry in payload.split(separator: "\0") {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq])
                if ["PWD", "OLDPWD", "SHLVL", "_", "TERM_PROGRAM", "TERM_SESSION_ID"].contains(key) { continue }
                base[key] = String(entry[entry.index(after: eq)...])
            }
        }
        base["PATH"] = augmentedPath(base["PATH"])
        return base
    }

    /// Adds common tool locations that may be missing from a GUI PATH.
    public static func augmentedPath(_ path: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in ["\(home)/.local/bin", "\(home)/.kimi-code/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
                      "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !parts.contains(extra) {
            parts.append(extra)
        }
        return parts.joined(separator: ":")
    }

    /// Finds an executable by name in PATH.
    public static func which(_ name: String, path: String?) -> String? {
        for dir in (path ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
