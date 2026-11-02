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
    @Published private(set) var checkState = ReckonUpdateCheckState()
    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    private let installedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let isDemo: Bool
    private var pendingOpenCheck = false

    private struct SavedCheck: Codable {
        let version: String
        let build: String
        let state: ReckonUpdateCheckState
    }

    var lastCheckedAt: Date? { checkState.lastCheckedAt ?? controller?.updater.lastUpdateCheckDate }
    var lastResultTitle: String {
        switch checkState.result {
        case .upToDate: "Up to date"
        case .available: "Update available"
        case .unavailable: "No compatible update"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case nil: "Not recorded"
        }
    }
    var statusTitle: String {
        if let notice = updateNotice { return notice.title }
        if checkState.isChecking { return "Checking for updates…" }
        switch checkState.result {
        case .upToDate: return "You’re up to date"
        case .available: return "Update available"
        case .unavailable: return "No compatible update"
        case .failed: return "Update check failed"
        case .skipped: return "Update skipped"
        case nil: return lastCheckedAt == nil ? "Not checked yet" : "No check result recorded"
        }
    }
    var statusImage: String {
        if updateNotice != nil { return "arrow.down.circle.fill" }
        switch checkState.result {
        case .upToDate: return "checkmark.circle"
        case .failed, .unavailable: return "exclamationmark.circle"
        default: return "arrow.down.circle"
        }
    }

    init(isDemo: Bool) {
        self.isDemo = isDemo
        super.init()
        guard !isDemo else { return }
        if let data = UserDefaults.standard.data(forKey: "ReckonUpdateCheck"),
           let saved = try? JSONDecoder().decode(SavedCheck.self, from: data),
           saved.version == installedVersion, saved.build == installedBuild {
            checkState = saved.state
            if saved.state.result == .available, let version = saved.state.latestVersion {
                updateNotice = .available(version: version)
            }
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updater.sendsSystemProfile = false
        updater.userAgentString = "Reckon/\(installedVersion)"
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettings() }
            },
            updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in
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

    /// Opening a view requests a silent probe; repeated opens share a one-minute cooldown.
    func checkWhenOpened() {
        guard !isDemo else { return }
        pendingOpenCheck = true
        checkPendingOpen()
    }

    func checkForUpdates() {
        guard !isDemo, canCheckForUpdates else { return }
        message = nil
        if !controller.updater.sessionInProgress { checkState.beginCheck(at: .now) }
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { recordAvailableUpdate(item) }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) { recordNoUpdate(error as NSError) }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                              state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            guard let url = update.fileURL, ReckonUpdateFeed.isAllowedDownload(url) else { return }
            if state.stage == .notDownloaded { recordAvailableUpdate(update) }
            else { updateNotice = .ready(version: update.displayVersionString) }
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        if let url = item.fileURL, ReckonUpdateFeed.isAllowedDownload(url) {
            updateNotice = .ready(version: item.displayVersionString)
        }
        return false
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip {
            updateNotice = nil
            checkState.skippedUpdate()
            saveCheck()
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { recordError(error as NSError) }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error { recordError(error as NSError) }
        checkState.finishCheck()
        refreshSettings()
    }

    private func recordNoUpdate(_ error: NSError) {
        let item = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        let isUpToDate = reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue
        checkState.foundNoUpdate(latestVersion: item?.displayVersionString ?? (isUpToDate ? installedVersion : nil),
                                 isUpToDate: isUpToDate, at: .now)
        updateNotice = nil
        message = isUpToDate ? nil : "No newer compatible update was offered. The release may be skipped or require a different macOS version."
        saveCheck()
    }

    private func recordError(_ error: NSError) {
        if error.domain == SUSparkleErrorDomain {
            if error.code == SUError.noUpdateError.rawValue {
                if checkState.isChecking { recordNoUpdate(error) }
                return
            }
            if error.code == SUError.installationCanceledError.rawValue {
                checkState.finishCheck()
                return
            }
        }
        checkState.failed(at: .now)
        if let notice = updateNotice { updateNotice = .available(version: notice.version) }
        message = "Could not check or install an update. Check your internet connection and try again."
        saveCheck()
    }

    private func recordAvailableUpdate(_ item: SUAppcastItem) {
        guard let url = item.fileURL, ReckonUpdateFeed.isAllowedDownload(url) else { return }
        checkState.foundUpdate(version: item.displayVersionString, at: .now)
        message = nil
        if updateNotice?.version != item.displayVersionString { updateNotice = .available(version: item.displayVersionString) }
        saveCheck()
    }

    private func saveCheck() {
        guard !isDemo, let data = try? JSONEncoder().encode(SavedCheck(version: installedVersion, build: installedBuild, state: checkState)) else { return }
        UserDefaults.standard.set(data, forKey: "ReckonUpdateCheck")
    }

    private func checkPendingOpen() {
        guard pendingOpenCheck else { return }
        let updater = controller.updater
        guard updater.automaticallyChecksForUpdates else { pendingOpenCheck = false; return }
        if case .ready = updateNotice { pendingOpenCheck = false; return }
        guard updater.canCheckForUpdates, !updater.sessionInProgress else { return }
        pendingOpenCheck = false
        guard checkState.beginAutomaticCheck(at: .now, enabled: true, sessionInProgress: false) else { return }
        message = nil
        updater.checkForUpdateInformation()
    }

    private func refreshSettings() {
        guard !isDemo else { return }
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        if !updater.sessionInProgress { checkState.finishCheck() }
        else if updateNotice == nil, !checkState.isChecking { checkState.beginCheck(at: .now) }
        checkPendingOpen()
    }
}
