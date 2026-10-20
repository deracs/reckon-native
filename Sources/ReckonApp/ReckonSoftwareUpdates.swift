import AppKit
import Combine
import ReckonCore
import Sparkle

/// Uses signed, architecture-specific GitHub feeds; bank data never enters update requests.
@MainActor
final class ReckonSoftwareUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var hasGitHubToken = false
    @Published private(set) var message: String?
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let isDemo: Bool

    init(isDemo: Bool) {
        self.isDemo = isDemo
        super.init()
        guard !isDemo else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        configureHeaders()
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

    func saveGitHubToken(_ token: String) {
        guard !isDemo else { return }
        do {
            try ReckonUpdateKeychain.saveToken(token)
            configureHeaders()
            controller.updater.resetUpdateCycle()
            message = "GitHub access saved in Keychain."
        } catch { message = "Could not save GitHub access. Use a fine-grained GitHub token and check Keychain access." }
    }

    func removeGitHubToken() {
        guard !isDemo else { return }
        do {
            try ReckonUpdateKeychain.deleteToken()
            configureHeaders()
            message = "GitHub access removed. Public updates still work."
        } catch { message = "Could not remove GitHub access from Keychain." }
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

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        message = "Could not check or install an update. For a private repository, save a GitHub token with Contents read access to reckon-native."
    }

    private func configureHeaders() {
        var headers = ["Accept": "application/vnd.github.raw+json", "X-GitHub-Api-Version": "2022-11-28"]
        do {
            if let token = try ReckonUpdateKeychain.loadToken() {
                headers["Authorization"] = "Bearer \(token)"
                hasGitHubToken = true
            } else { hasGitHubToken = false }
        } catch {
            message = "Could not read GitHub access from Keychain."
            hasGitHubToken = false
        }
        controller.updater.httpHeaders = headers
    }

    private func refreshSettings() {
        guard !isDemo else { return }
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
    }
}
