#if os(macOS)
import Observation
import Sparkle

/// Keeps the Mac app up to date with Sparkle. Each release from
/// scripts/release.sh carries an appcast.xml on the public
/// sichx/jplus-releases repository; Sparkle reads the newest one daily and
/// downloads a newer version in the background. The sidebar then shows an
/// update button that installs it and relaunches, and quitting installs it
/// too. The iPhone and iPad app updates through the App Store.
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// The newer version the sidebar offers; nil when up to date.
    private(set) var availableVersion: String?
    /// Settings' "Check for updates automatically".
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    /// Installs the downloaded update and relaunches, once Sparkle has one.
    @ObservationIgnored private var installNow: (() -> Void)?

    override init() {
        checksAutomatically = true
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    /// Check for Updates…: Sparkle's window says whether there's anything new.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// The sidebar button. An update Sparkle couldn't download on its own
    /// opens in Sparkle's window instead, with an Install button.
    func installUpdate() {
        if let installNow {
            installNow()
        } else {
            controller.checkForUpdates(nil)
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        installNow = immediateInstallHandler
        return true
    }

    // MARK: SPUStandardUserDriverDelegate

    // The sidebar button stands in for Sparkle's alert when a scheduled check
    // finds an update it can't download by itself.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            availableVersion = update.displayVersionString
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Skipped, dismissed or failed; a downloaded update still installs.
        if installNow == nil {
            availableVersion = nil
        }
    }
}
#endif
