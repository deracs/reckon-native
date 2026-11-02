import Foundation
import ReckonCore

struct ReckonUpdateCheckStateTests {
    func openingViewsCoalescesChecksAndRespectsPreferences() throws {
        var state = ReckonUpdateCheckState()
        let now = Date(timeIntervalSince1970: 1_000)
        try bankExpect(!state.beginAutomaticCheck(at: now, enabled: false, sessionInProgress: false))
        try bankExpect(!state.beginAutomaticCheck(at: now, enabled: true, sessionInProgress: true))
        try bankExpect(state.beginAutomaticCheck(at: now, enabled: true, sessionInProgress: false))
        try bankExpect(!state.beginAutomaticCheck(at: now.addingTimeInterval(120), enabled: true, sessionInProgress: false))
        state.foundNoUpdate(latestVersion: "1.0", isUpToDate: true, at: now.addingTimeInterval(1))
        try bankExpect(!state.beginAutomaticCheck(at: now.addingTimeInterval(59), enabled: true, sessionInProgress: false))
        try bankExpect(state.beginAutomaticCheck(at: now.addingTimeInterval(60), enabled: true, sessionInProgress: false))
    }

    func failuresDoNotClaimTheAppIsCurrentOrEraseTheKnownRelease() throws {
        var state = ReckonUpdateCheckState()
        let now = Date(timeIntervalSince1970: 1_000)
        state.foundUpdate(version: "1.1", at: now)
        state.beginCheck(at: now.addingTimeInterval(1))
        state.failed(at: now.addingTimeInterval(2))
        try bankExpect(state.result == .failed)
        try bankExpect(state.latestVersion == "1.1")
        try bankExpect(!state.isChecking)
        state.foundNoUpdate(latestVersion: "1.2", isUpToDate: false, at: now.addingTimeInterval(3))
        try bankExpect(state.result == .unavailable)
        try bankExpect(state.latestVersion == "1.2")
        state.skippedUpdate()
        try bankExpect(state.result == .skipped)
    }

    func savedResultsRestoreWithoutRestoringAnInflightCheck() throws {
        var state = ReckonUpdateCheckState()
        let now = Date(timeIntervalSince1970: 1_000)
        state.foundUpdate(version: "1.1", at: now)
        state.beginCheck(at: now.addingTimeInterval(60))
        let restored = try JSONDecoder().decode(ReckonUpdateCheckState.self, from: JSONEncoder().encode(state))
        try bankExpect(!restored.isChecking)
        try bankExpect(restored.result == .available)
        try bankExpect(restored.latestVersion == "1.1")
        try bankExpect(restored.lastCheckedAt == now)
    }
}
