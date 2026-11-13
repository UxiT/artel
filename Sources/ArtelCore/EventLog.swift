import Foundation

/// Per-session append-only JSONL log of hook events.
///
/// The hook binary appends here *and* pings the live socket. If the app wasn't running,
/// replaying the log on launch restores each session's state.
public enum EventLog {
    public static func append(_ event: HookEvent, dir: URL = AppPaths.eventsDir) throws {
        var line = try JSONEncoder.artel.encode(event)
        line.append(0x0A)
        let url = dir.appendingPathComponent("\(event.artelSessionID).jsonl")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        // A single write() with O_APPEND is atomic for small lines, so concurrent hooks don't interleave.
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    public static func read(sessionID: String, dir: URL = AppPaths.eventsDir) -> [HookEvent] {
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder.artel
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HookEvent.self, from: Data($0)) }
    }

    /// Folds the whole log into the latest status.
    public static func replay(sessionID: String, dir: URL = AppPaths.eventsDir) -> SessionStatus? {
        let events = read(sessionID: sessionID, dir: dir)
        guard !events.isEmpty else { return nil }
        return events.reduce(SessionStatus(since: events[0].timestamp)) { $0.applying($1) }
    }

    /// Keeps logs small: rewrites a log longer than `maxLines` to its tail.
    public static func compact(sessionID: String, maxLines: Int = 2000, dir: URL = AppPaths.eventsDir) {
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > maxLines else { return }
        var out = Data()
        for line in lines.suffix(maxLines) { out.append(contentsOf: line); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }

    public static func remove(sessionID: String, dir: URL = AppPaths.eventsDir) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sessionID).jsonl"))
    }
}
