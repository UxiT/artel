import AppKit
import ArtelCore

/// First launch after the rename from Aide: quits a still running Aide (its sessions survive that) and
/// takes over its data and preferences. The tmux part runs later, once tmux is found (`LegacyAide`).
enum LegacyMigration {
    static func run() {
        guard !AppPaths.isOverridden else { return }
        quitAide()
        LegacyAide.migrateDataDirectory()
        migrateDefaults()
    }

    private static func quitAide() {
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: LegacyAide.bundleID)
        }
        guard !running().isEmpty else { return }
        running().forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while !running().isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard !running().isEmpty else { return }
        // Two apps managing the same sessions and data dir would fight over them.
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Aide всё ещё запущен"
        alert.informativeText = "Artel — новое название Aide. Закройте Aide и запустите Artel снова: агенты в сессиях продолжат работать."
        alert.runModal()
        exit(0)
    }

    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, defaults.persistentDomain(forName: id)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: LegacyAide.bundleID), !old.isEmpty else { return }
        defaults.setPersistentDomain(old, forName: id)
    }
}
