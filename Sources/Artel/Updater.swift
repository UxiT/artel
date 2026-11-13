import ArtelCore
import Combine
import Sparkle
import SwiftUI

/// Self-update through Sparkle: the appcast of the latest GitHub release (`SUFeedURL`), checked once a day
/// and from the app menu. Off when the build has no EdDSA key (`SUPublicEDKey`), when it doesn't run from
/// an .app bundle (`swift run`) and in a dev instance with its own `ARTEL_HOME`.
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard Bundle.main.bundleURL.pathExtension == "app", !key.isEmpty, !AppPaths.isOverridden else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var isEnabled: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Проверить обновления…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
