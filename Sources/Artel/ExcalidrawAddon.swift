import ArtelCore
import CryptoKit
import Foundation
import Observation

/// Optional exact rendering of `.excalidraw` drawings with Excalidraw's own exporter (`@excalidraw/utils`, MIT).
/// It is one ~20 MB ES module (fonts inlined, Cyrillic and CJK included), so it isn't shipped with the app:
/// the operator downloads it on demand into Application Support. The pinned file is checked by sha256;
/// without it the preview draws diagrams with Artel's own rough.js renderer.
@MainActor @Observable
final class ExcalidrawAddon {
    static let shared = ExcalidrawAddon()

    nonisolated static let version = "0.1.8"
    nonisolated static let sha256 = "d859cee50c6148ba53192da5454d48d8370ced75449a678b6baefc293c29fe6e"
    static let sizeMB = 20
    /// The same file on two CDNs (both mirror npm); the hash decides.
    nonisolated static let sources = [
        "https://cdn.jsdelivr.net/npm/@excalidraw/utils@\(version)/dist/prod/index.js",
        "https://unpkg.com/@excalidraw/utils@\(version)/dist/prod/index.js",
    ]

    nonisolated static var file: URL {
        AppPaths.root.appendingPathComponent("renderers/excalidraw-utils-\(version)/index.js")
    }

    enum State: Equatable {
        case notInstalled, downloading, installed
        case failed(String)
    }

    private(set) var state: State
    /// Bumped on install / removal: open previews re-render their drawings.
    private(set) var revision = 0

    private init() {
        state = FileManager.default.fileExists(atPath: Self.file.path) ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    func install() {
        guard state != .downloading else { return }
        state = .downloading
        Task {
            do {
                let data = try await Self.download()
                let dir = Self.file.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: Self.file, options: .atomic)
                state = .installed
                revision += 1
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.file.deletingLastPathComponent())
        state = .notInstalled
        revision += 1
    }

    private nonisolated static func download() async throws -> Data {
        var lastError: Error = URLError(.cannotFindHost)
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue("Artel/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == sha256 else {
                    throw NSError(domain: "Artel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Контрольная сумма не совпала"])
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
