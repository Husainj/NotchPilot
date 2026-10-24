import AppKit
import Observation
import Sparkle

/// Wraps Sparkle. Updates are only enabled once a real EdDSA public key is in
/// Info.plist (see `make sparkle-keys`), so dev builds never show update errors.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        else { return false }
        return !key.isEmpty && !key.contains("REPLACE") && !feed.contains("USERNAME") && !feed.contains("REPLACE")
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    func start() {
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't configured in this build."
            alert.informativeText = "Set SUFeedURL to your GitHub Pages appcast and run `make sparkle-keys` (see README → Releasing)."
            alert.runModal()
            return
        }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // The app is a menu-bar app with no Dock icon, so let Sparkle use gentle
    // reminders and bring its window to the front when an update is found.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { NSApp.activate() }
    }
}
