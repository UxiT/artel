import ArtelCore
import Combine
import Sparkle
import SwiftUI

/// Self-update through Sparkle: the appcast of the latest GitHub release (`SUFeedURL`), checked at every launch,
/// once a day while the app runs and from the app menu. A found update opens Sparkle's dialog (release notes,
/// install / remind later / skip this version). Off when the build has no EdDSA key (`SUPublicEDKey`), when it
/// doesn't run from an .app bundle (`swift run`) and in a dev instance with its own `ARTEL_HOME`.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    /// Dev hook: `ARTEL_UPDATE_FEED=<appcast URL>` turns the updater on in a dev instance and points it at that feed.
    private let testFeed = ProcessInfo.processInfo.environment["ARTEL_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }

    override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard Bundle.main.bundleURL.pathExtension == "app", !key.isEmpty, !AppPaths.isOverridden || testFeed != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        // The daily schedule alone skips launches within a day of the last check, so check at every launch too.
        // Sparkle's advice for that: right after the updater starts and only while automatic checks are on.
        // Skipped versions aren't offered again; "remind later" offers the update at the next launch.
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    var isEnabled: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func feedURLString(for updater: SPUUpdater) -> String? { testFeed }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
