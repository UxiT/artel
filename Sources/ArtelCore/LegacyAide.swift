import Foundation

/// Artel used to be called Aide. This keeps an existing Aide setup working after the rename:
/// the data directory, running sessions, task folders in projects and files written under the old name.
/// Nothing here is needed for a clean install; drop it once nobody upgrades from Aide any more.
public enum LegacyAide {
    public static let bundleID = "dev.aide.Aide"
    /// Task folder of projects that got tasks before the rename. It is used in place and never moved
    /// by the app: committed task files stay where they are until the operator runs `git mv .aide .artel`.
    public static let projectDirName = ".aide"
    /// Environment of sessions started by Aide (their hooks may call the new hook binary).
    public static let sessionIDEnv = "AIDE_SESSION_ID"
    public static let socketEnv = "AIDE_SOCKET"
    public static let eventsDirEnv = "AIDE_EVENTS_DIR"

    static let dataDirName = "Aide"
    static let hookBinaryName = "aide-hook"
    static let tmuxSocketName = "aide"
    static let tmuxSessionPrefix = "aide-"
    static let kimiConfigBegin = "# >>> aide"
    static let kimiConfigEnd = "# <<< aide"
    /// `TaskHistoryEntry.Actor` written as "aide".
    static let historyActor = "aide"
    /// JSON keys renamed together with the app (events, state.json).
    static let renamedKeys = ["aideSessionID": "artelSessionID", "storeAideInGit": "storeArtelInGit"]

    // MARK: - Data directory

    /// Moves `~/Library/Application Support/Aide` to Artel's data directory (once) and leaves a symlink
    /// in its place: sessions started by Aide keep writing events and pinging the socket via the old paths.
    @discardableResult
    public static func migrateDataDirectory() -> Bool {
        guard !AppPaths.isOverridden else { return false }
        let new = AppPaths.root
        return migrateDataDirectory(from: new.deletingLastPathComponent().appendingPathComponent(dataDirName), to: new)
    }

    static func migrateDataDirectory(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        // attributesOfItem doesn't follow symlinks: an already migrated directory is a link.
        guard (try? fm.attributesOfItem(atPath: new.path)) == nil,
              (try? fm.attributesOfItem(atPath: old.path))?[.type] as? FileAttributeType == .typeDirectory else { return false }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            return false
        }
        try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: new.lastPathComponent)
        return true
    }

    // MARK: - tmux

    /// Sessions started by Aide run in its `aide` tmux server. While that server is up, Artel keeps working
    /// through it (so the agents go on instead of being restarted) and renames its sessions to Artel's names.
    /// Once it is gone (after a reboot) returns `tmux` unchanged and removes, from `dataRoot`, the leftovers
    /// that kept those sessions working. A dev instance (`ARTEL_HOME`, no `dataRoot`) leaves Aide's server alone:
    /// renaming sessions under a still running Aide would make it restart them.
    public static func adoptTmuxServer(_ tmux: Tmux, dataRoot: URL? = AppPaths.isOverridden ? nil : AppPaths.root) -> Tmux {
        guard let dataRoot, tmux.socketName == Tmux.defaultSocketName else { return tmux }
        let socket = tmuxSocketDirectory(environment: tmux.environment) + "/" + tmuxSocketName
        guard HookSocket.isListening(socket) else {
            removeLeftovers(dataRoot: dataRoot)
            return tmux
        }
        let legacy = Tmux(executable: tmux.executable, configFile: tmux.configFile, environment: tmux.environment,
                          socketName: tmuxSocketName)
        for name in legacy.listSessions() where name.hasPrefix(tmuxSessionPrefix) {
            legacy.rename(name, to: Tmux.sessionPrefix + name.dropFirst(tmuxSessionPrefix.count))
        }
        return legacy
    }

    private static func removeLeftovers(dataRoot: URL) {
        let fm = FileManager.default
        let oldData = dataRoot.deletingLastPathComponent().appendingPathComponent(dataDirName).path
        if (try? fm.destinationOfSymbolicLink(atPath: oldData)) == dataRoot.lastPathComponent {
            try? fm.removeItem(atPath: oldData)
        }
        try? fm.removeItem(at: dataRoot.appendingPathComponent("bin").appendingPathComponent(hookBinaryName))
    }

    /// Where tmux keeps `-L` sockets: `$TMUX_TMPDIR/tmux-<uid>` (default `/tmp`).
    static func tmuxSocketDirectory(environment: [String: String]) -> String {
        let base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return (base as NSString).appendingPathComponent("tmux-\(getuid())")
    }

    // MARK: - Old file formats

    /// Reads JSON written under the old name: maps renamed keys to the current ones.
    static func keyDecodingStrategy() -> JSONDecoder.KeyDecodingStrategy {
        .custom { path in
            let key = path[path.count - 1]
            guard let renamed = renamedKeys[key.stringValue] else { return key }
            return RenamedKey(stringValue: renamed)
        }
    }

    private struct RenamedKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
