import ArtelCore
import CryptoKit
import Foundation
import Observation

/// Optional Excalidraw for the documentation: the editor (draw `.excalidraw` files inside Artel) and Excalidraw's
/// own SVG export for the preview. It is React + `@excalidraw/excalidraw` (MIT) with Excalidraw's fonts, built by
/// `scripts/build-excalidraw-editor.sh` into one zip (~15 MB) and published as a GitHub release of Artel — too big
/// to ship in the app, so the operator downloads it on demand. The zip is checked against the sha256 compiled in
/// and unpacked into Application Support. Without it, drawings are shown by the built-in rough.js renderer and
/// can't be edited in Artel.
///
/// `ARTEL_EXCALIDRAW_BUNDLE=<zip>` installs a local build instead (development; the hash isn't checked).
@MainActor @Observable
final class ExcalidrawAddon {
    static let shared = ExcalidrawAddon()

    /// `<@excalidraw/excalidraw version>-<bundle revision>`, as printed by the build script.
    nonisolated static let version = "0.18.1-1"
    nonisolated static let sha256 = "4fb2331579641599464c41c7656fb9d58d1d96586f5684cb968795de88de3078"
    static let sizeMB = 15
    nonisolated static let source = URL(
        string: "https://github.com/UxiT/artel/releases/download/excalidraw-\(version)/excalidraw-\(version).zip")!

    nonisolated static var directory: URL {
        AppPaths.root.appendingPathComponent("renderers/excalidraw-\(version)", isDirectory: true)
    }

    /// The module the preview and the editor import.
    nonisolated static var entry: URL { directory.appendingPathComponent("entry.js") }

    enum State: Equatable {
        case notInstalled, downloading, installed
        case failed(String)
    }

    private(set) var state: State
    /// Bumped on install / removal: open previews re-render their drawings.
    private(set) var revision = 0

    private init() {
        state = FileManager.default.fileExists(atPath: Self.entry.path) ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    func install() {
        guard state != .downloading else { return }
        state = .downloading
        Task {
            do {
                let zip = try await Self.fetchZip()
                try await Self.unpack(zip)
                state = .installed
                revision += 1
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.directory)
        state = .notInstalled
        revision += 1
    }

    /// The zip on disk: the local override, or the release asset, verified.
    private nonisolated static func fetchZip() async throws -> URL {
        if let local = ProcessInfo.processInfo.environment["ARTEL_EXCALIDRAW_BUNDLE"], !local.isEmpty {
            return URL(fileURLWithPath: local)
        }
        var request = URLRequest(url: source, timeoutInterval: 300)
        request.setValue("Artel/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Artel", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The download isn't available (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == sha256 else {
            throw NSError(domain: "Artel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch"])
        }
        return file
    }

    /// Unpacks into a fresh folder next to the target, then swaps it in; older versions are removed.
    private nonisolated static func unpack(_ zip: URL) async throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".excalidraw-\(UUID().uuidString)", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: staging.appendingPathComponent("entry.js").path) else {
            try? fm.removeItem(at: staging)
            throw NSError(domain: "Artel", code: 3, userInfo: [NSLocalizedDescriptionKey: "The archive is damaged"])
        }
        for old in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("excalidraw") {
            try? fm.removeItem(at: old)
        }
        try fm.moveItem(at: staging, to: directory)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
