import Combine
import Sparkle
import SwiftUI

/// Thin SwiftUI-friendly wrapper around Sparkle's standard updater. Updates are verified by the
/// app's EdDSA key (SUPublicEDKey in Info.plist) against the appcast at SUFeedURL — works even though
/// the app is only ad-hoc signed (no Apple notarization).
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// User-initiated check — shows Sparkle's UI (progress, release notes, install prompt).
    func checkForUpdates() { controller.updater.checkForUpdates() }

    /// Background auto-check toggle (defaults on via SUEnableAutomaticChecks).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
