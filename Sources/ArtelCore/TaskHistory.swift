import Foundation

/// One event in a task's life. Stored as JSON lines in `history.jsonl` next to task.md.
public struct TaskHistoryEntry: Codable, Equatable, Sendable {
    public enum Actor: String, Codable, Sendable {
        case `operator`, agent, artel
        public var title: String {
            switch self {
            case .operator: "You"
            case .agent: "Agent"
            case .artel: "Artel"
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let actor = Actor(rawValue: raw == LegacyAide.historyActor ? Actor.artel.rawValue : raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown actor \(raw)"))
            }
            self = actor
        }
    }

    public enum Kind: String, Codable, Sendable {
        /// created · status change · agent session started · misc.
        /// `comment`, `artifact`, `merge` and `conflict` come from the removed plan/review workflow
        /// and are only read from old histories.
        case created, status, comment, launch, artifact, merge, conflict, note
    }

    public var date: Date
    public var actor: Actor
    public var kind: Kind
    public var text: String
    public var from: TaskStatus?
    public var to: TaskStatus?
    /// Artifact file name (plan.md…) for `.artifact`.
    public var file: String?
    public var iteration: Int?

    public init(date: Date = Date(), actor: Actor, kind: Kind, text: String = "", from: TaskStatus? = nil,
                to: TaskStatus? = nil, file: String? = nil, iteration: Int? = nil) {
        self.date = date
        self.actor = actor
        self.kind = kind
        self.text = text
        self.from = from
        self.to = to
        self.file = file
        self.iteration = iteration
    }
}

public enum TaskHistory {
    public static let fileName = "history.jsonl"

    public static func file(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Appends one line (O_APPEND, so concurrent writers don't clobber each other).
    public static func append(_ entry: TaskHistoryEntry, in directory: URL) throws {
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let url = file(in: directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    /// Entries in file order; unreadable lines are skipped.
    public static func load(from directory: URL) -> [TaskHistoryEntry] {
        guard let text = try? String(contentsOf: file(in: directory), encoding: .utf8) else { return [] }
        let d = decoder
        return text.split(separator: "\n").compactMap { try? d.decode(TaskHistoryEntry.self, from: Data($0.utf8)) }
    }

    /// The task's timeline, oldest first; tasks older than the log get a synthetic "created" entry.
    public static func timeline(for task: ArtelTask) -> [TaskHistoryEntry] {
        // Old workflow stages collapse into one status: their transitions may now read "X → X".
        var entries = load(from: task.directory).filter { $0.kind != .status || $0.from == nil || $0.from != $0.to }
        if !entries.contains(where: { $0.kind == .created }) {
            entries.append(TaskHistoryEntry(date: task.created, actor: .operator, kind: .created, text: "Task created"))
        }
        return entries.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset
        }.map(\.element)
    }
}
