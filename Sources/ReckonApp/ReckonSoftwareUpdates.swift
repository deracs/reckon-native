import AppKit
import Combine
import ReckonCore
import Sparkle

/// Uses signed, architecture-specific GitHub feeds; bank data never enters update requests.
@MainActor
final class ReckonSoftwareUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var message: String?
    @Published private(set) var updateNotice: ReckonUpdateNotice?
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let isDemo: Bool

    init(isDemo: Bool) {
        self.isDemo = isDemo
        super.init()
        guard !isDemo else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updater.sendsSystemProfile = false
        updater.userAgentString = "Reckon/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")"
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettings() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettings() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettings() }
            }
        ]
        controller.startUpdater()
        refreshSettings()
    }

    func checkForUpdates() {
        guard !isDemo, canCheckForUpdates else { return }
        message = nil
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard !isDemo else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        refreshSettings()
    }

    func setAutomaticInstalls(_ enabled: Bool) {
        guard !isDemo else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
        refreshSettings()
    }

    func feedURLString(for updater: SPUUpdater) -> String? { ReckonUpdateFeed.feedURL.absoluteString }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let url = item.fileURL, ReckonUpdateFeed.isAllowedDownload(url) else {
            throw NSError(domain: "nz.reckon.native.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Reckon updates must come from its GitHub release assets."])
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        recordAvailableUpdate(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateNotice = nil
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                              state: SPUUserUpdateState) {
        // Sparkle's standard user driver delivers UI callbacks on the main thread.
        MainActor.assumeIsolated {
            guard let url = update.fileURL, ReckonUpdateFeed.isAllowedDownload(url) else { return }
            if state.stage == .notDownloaded {
                recordAvailableUpdate(update)
            } else {
                updateNotice = .ready(version: update.displayVersionString)
            }
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        if let url = item.fileURL, ReckonUpdateFeed.isAllowedDownload(url) {
            updateNotice = .ready(version: item.displayVersionString)
        }
        // Sparkle retains installation ownership and its normal install-on-quit behavior.
        return false
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip { updateNotice = nil }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        updateNotice = nil
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain {
            if failure.code == SUError.noUpdateError.rawValue {
                message = "You’re up to date."
                return
            }
            if failure.code == SUError.installationCanceledError.rawValue {
                message = nil
                return
            }
        }
        message = "Could not check or install an update. Check your internet connection and try again."
    }

    private func recordAvailableUpdate(_ item: SUAppcastItem) {
        guard let url = item.fileURL, ReckonUpdateFeed.isAllowedDownload(url) else { return }
        if updateNotice?.version != item.displayVersionString {
            updateNotice = .available(version: item.displayVersionString)
        }
    }

    private func refreshSettings() {
        guard !isDemo else { return }
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
    }
}
