import Foundation
import Testing
@testable import ArtelCore

/// Upgrading an Aide setup (the app's former name) in place.
@Suite struct LegacyAideTests {
    func tempDir(_ prefix: String = "artel-legacy") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func dataDirectoryMovesOnceAndKeepsOldPathWorking() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let old = root.appendingPathComponent("Aide"), new = root.appendingPathComponent("Artel")
        try fm.createDirectory(at: old.appendingPathComponent("events"), withIntermediateDirectories: true)
        try "{}".write(to: old.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        #expect(LegacyAide.migrateDataDirectory(from: old, to: new))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("state.json").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: old.path) == "Artel")
        // Sessions started by Aide still find their events dir through the old path.
        #expect(fm.fileExists(atPath: old.appendingPathComponent("events").path))
        #expect(!LegacyAide.migrateDataDirectory(from: old, to: new))
    }

    @Test func dataDirectoryIsLeftAloneWhenArtelAlreadyHasOne() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let old = root.appendingPathComponent("Aide"), new = root.appendingPathComponent("Artel")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        #expect(!LegacyAide.migrateDataDirectory(from: old, to: new))
        #expect((try? fm.destinationOfSymbolicLink(atPath: old.path)) == nil)
    }

    @Test func oldJSONKeysAndHistoryActorStillDecode() throws {
        let event = try JSONDecoder.artel.decode(HookEvent.self, from: Data(
            #"{"aideSessionID":"ab12","name":"Stop","timestamp":"2026-11-13T10:00:00Z"}"#.utf8))
        #expect(event.artelSessionID == "ab12")
        let project = try JSONDecoder.artel.decode(Project.self, from: Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"p","path":"/tmp/p","storeAideInGit":false}"#.utf8))
        #expect(project.storeArtelInGit == false)
        let entry = try TaskHistory.decoder.decode(TaskHistoryEntry.self, from: Data(
            #"{"date":"2026-11-13T10:00:00Z","actor":"aide","kind":"note","text":"Worktree удалён"}"#.utf8))
        #expect(entry.actor == .artel)
    }

    @Test func projectKeepsItsAideFolderUntilRenamed() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "p", path: root.path)
        #expect(TaskStore.dirName(project) == ".artel")

        let legacy = root.appendingPathComponent(".aide/tasks/AIDE-1-old")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "---\nid: AIDE-1\ntitle: Old\nstatus: new\n---\nbody\n"
            .write(to: legacy.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        #expect(TaskStore.dirName(project) == ".aide")
        #expect(TaskStore.load(project).map(\.taskID) == ["AIDE-1"])
        let created = try TaskStore.create(project: project, title: "New", existing: TaskStore.load(project))
        #expect(created.directory.path.contains("/.aide/tasks/"))

        // Once the operator moves it (git mv .aide .artel), the new folder wins.
        try FileManager.default.moveItem(at: root.appendingPathComponent(".aide"), to: root.appendingPathComponent(".artel"))
        #expect(TaskStore.dirName(project) == ".artel")
        #expect(TaskStore.load(project).count == 2)
    }

    @Test func kimiBlockWrittenByAideIsReplaced() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try "model = \"k2\"\n\n# >>> aide\n[[hooks]]\nevent = \"Stop\"\ncommand = \"'/old/aide-hook'\"\n# <<< aide\n\n[ui]\ntheme = \"dark\"\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try KimiCodeAgent.installConfig(hookBinary: "/new/artel-hook", to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("aide"))
        #expect(text.contains("/new/artel-hook"))
        #expect(text.hasPrefix("model = \"k2\""))
        #expect(text.contains("[ui]\ntheme = \"dark\""))
        // Both blocks present (Aide and Artel both ran): the old one is dropped.
        try (text + "\n# >>> aide\n# <<< aide\n").write(to: url, atomically: true, encoding: .utf8)
        try KimiCodeAgent.installConfig(hookBinary: "/new/artel-hook", to: url)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("aide"))
    }

    static let tmuxBinary: String? = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [repo.appendingPathComponent("build/vendor/tmux").path, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs against a private TMUX_TMPDIR, never the real `aide` / `artel` servers.
    @Test(.enabled(if: tmuxBinary != nil)) func runningAideSessionsAreAdopted() throws {
        let fm = FileManager.default
        // Short path: tmux socket paths must fit sun_path.
        let tmp = URL(fileURLWithPath: "/tmp/artel-t-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let data = try tempDir()
        defer { try? fm.removeItem(at: tmp); try? fm.removeItem(at: data) }
        let env = ["TMUX_TMPDIR": tmp.path, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let exe = try #require(Self.tmuxBinary)
        func legacy(_ args: [String]) throws -> ProcessResult {
            try Shell.run(exe, ["-L", "aide", "-f", "/dev/null"] + args, environment: env, timeout: 10)
        }
        #expect(try legacy(["new-session", "-d", "-s", "aide-ab12", "--", "sleep", "60"]).ok)
        defer { _ = try? legacy(["kill-server"]) }

        // Leftovers of a migrated data dir: Aide → Artel symlink and the old hook binary.
        let artelData = data.appendingPathComponent("Artel")
        try fm.createDirectory(at: artelData.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: data.appendingPathComponent("Aide").path, withDestinationPath: "Artel")
        try "old".write(to: artelData.appendingPathComponent("bin/aide-hook"), atomically: true, encoding: .utf8)

        let fresh = Tmux(executable: exe, configFile: URL(fileURLWithPath: "/dev/null"), environment: env)
        #expect(LegacyAide.adoptTmuxServer(fresh, dataRoot: nil).socketName == "artel")  // dev instance: hands off
        #expect(try legacy(["list-sessions", "-F", "#{session_name}"]).stdout == "aide-ab12\n")

        let tmux = LegacyAide.adoptTmuxServer(fresh, dataRoot: artelData)
        #expect(tmux.socketName == "aide")
        #expect(tmux.listSessions() == ["artel-ab12"])
        #expect(tmux.hasSession("artel-ab12"))
        #expect(tmux.attachArgs("artel-ab12").starts(with: ["-L", "aide"]))
        // Still needed by the adopted sessions.
        #expect(fm.fileExists(atPath: artelData.appendingPathComponent("bin/aide-hook").path))
        #expect(LegacyAide.adoptTmuxServer(fresh, dataRoot: artelData).listSessions() == ["artel-ab12"])  // idempotent

        // The old server is gone (its socket file stays, stale): back to Artel's own server, leftovers removed.
        #expect(try legacy(["kill-server"]).ok)
        let own = LegacyAide.adoptTmuxServer(fresh, dataRoot: artelData)
        #expect(own.socketName == "artel")
        #expect((try? fm.destinationOfSymbolicLink(atPath: data.appendingPathComponent("Aide").path)) == nil)
        #expect(!fm.fileExists(atPath: artelData.appendingPathComponent("bin/aide-hook").path))
        try own.newSession(name: "artel-cd34", cwd: tmp.path, env: [:], command: ["sleep", "60"])
        #expect(own.listSessions() == ["artel-cd34"])
        _ = try? Shell.run(exe, ["-L", "artel", "kill-server"], environment: env, timeout: 10)
    }
}
