import Foundation

/// Locations of everything Artel keeps on disk outside of projects.
///
/// `ARTEL_HOME` overrides the root (used by tests and by a second dev instance).
public enum AppPaths {
    public static var root: URL {
        if let override = homeOverride { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Artel", isDirectory: true)
    }

    /// `ARTEL_HOME` is set: a dev/test instance that must not touch the real data.
    public static var isOverridden: Bool { homeOverride != nil }

    private static var homeOverride: String? {
        ProcessInfo.processInfo.environment["ARTEL_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// App state: projects, sessions, layout, settings.
    public static var stateFile: URL { root.appendingPathComponent("state.json") }
    /// One JSONL file of hook events per session; survives app restarts.
    public static var eventsDir: URL { root.appendingPathComponent("events", isDirectory: true) }
    /// Unix socket the app listens on for live hook events.
    public static var socket: URL {
        let preferred = root.appendingPathComponent("hook.sock")
        // sun_path holds 104 bytes; a long ARTEL_HOME falls back to a short per-user path.
        if preferred.path.utf8.count < 100 { return preferred }
        var hash: UInt64 = 5381
        for b in root.path.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return URL(fileURLWithPath: "/tmp/artel-\(getuid())-\(String(hash, radix: 36)).sock")
    }
    /// Config for Artel's private tmux server.
    public static var tmuxConf: URL { root.appendingPathComponent("tmux.conf") }
    /// Settings file passed to `claude --settings`: only Artel's hooks.
    public static var claudeSettings: URL { root.appendingPathComponent("claude-settings.json") }
    /// Stable copies of helper binaries (the app bundle may move).
    public static var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public static var hookBinary: URL { binDir.appendingPathComponent("artel-hook") }
    public static var bundledTmux: URL { binDir.appendingPathComponent("tmux") }
    /// Leftovers of the removed aide-mcp integration, deleted on start-up.
    public static var obsolete: [URL] { [binDir.appendingPathComponent("aide-mcp"), root.appendingPathComponent("mcp", isDirectory: true)] }

    public static func eventsFile(sessionID: String) -> URL {
        eventsDir.appendingPathComponent("\(sessionID).jsonl")
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, eventsDir, binDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Environment variables Artel sets for every agent session; the hook binary reads them.
public enum ArtelEnv {
    public static let sessionID = "ARTEL_SESSION_ID"
    public static let socket = "ARTEL_SOCKET"
    public static let eventsDir = "ARTEL_EVENTS_DIR"
}
