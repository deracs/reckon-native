import Foundation

struct BankCheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func bankExpect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard try condition() else { throw BankCheckFailure(message: "Expectation failed at \(file):\(line)") }
}

func bankRequire<Value>(_ value: Value?, file: StaticString = #fileID, line: UInt = #line) throws -> Value {
    guard let value else { throw BankCheckFailure(message: "Required value missing at \(file):\(line)") }
    return value
}

func bankExpectError(_ operation: () throws -> Void, file: StaticString = #fileID, line: UInt = #line) throws {
    do { try operation() }
    catch { return }
    throw BankCheckFailure(message: "Expected an error at \(file):\(line)")
}

private struct BankCheck {
    let name: String
    let run: @Sendable () async throws -> Void
}

@main struct BankCheckRunner {
    static func main() async {
        let dashboard = BankDashboardTests()
        let api = ReckonAPIClientTests()
        let backend = BundledBackendTests()
        let journal = BankJournalTests()
        var checks: [BankCheck] = [
            BankCheck(name: "Balance limit crossings and notification opt-out") { try journal.balanceLimitsOnlyAlertOnCrossings() },
            BankCheck(name: "Charge increase baselines and deduplication") { try journal.chargeIncreasesDoNotAlertOnFirstObservationOrRepeats() },
            BankCheck(name: "Ninety daily observations with currency separation") { try journal.historyKeepsNinetyDailyObservationsAndPreservesCurrencies() },
            BankCheck(name: "Since-last-look IDs and changed account scope") { try journal.activityComparesIDsAndRejectsChangedLiquidScope() },
            BankCheck(name: "Encrypted history roundtrip, wrong key, and tampering") { try journal.encryptedHistoryRoundTripsWithoutPlaintextAndRejectsTampering() },
            BankCheck(name: "Upcoming bills, payday, and calendar boundaries") { try journal.forecastBillsPaydayAndAucklandCalendar() },
            BankCheck(name: "Bank totals preserve decimal precision, debt, and currencies") { try dashboard.bankCurrencyBalancesSumPreciselyAndIncludeDebt() },
            BankCheck(name: "Bank grouping retains all accounts and currencies") { try dashboard.accountGroupsRetainEveryAccountAndCurrency() },
            BankCheck(name: "Ten-minute session reuse, expiry, and view dismissal") { try await ReckonAppLockTests().reusesSessionUntilTenMinuteBoundary() },
            BankCheck(name: "Session timeout starts after authentication completes") { try await ReckonAppLockTests().sessionStartsWhenAuthenticationCompletes() },
            BankCheck(name: "Fresh authentication for every unlocked session") { try await ReckonAppLockTests().requiresAuthenticationOnEverySession() },
            BankCheck(name: "Rejected authentication keeps data locked") { try await ReckonAppLockTests().rejectionKeepsAccountsLocked() },
            BankCheck(name: "Late success cannot reopen locked accounts") { try await ReckonAppLockTests().lateSuccessCannotUnlockAfterLock() },
            BankCheck(name: "Old authentication reply cannot unlock new session") { try await ReckonAppLockTests().previousReplyCannotUnlockNewAttempt() },
            BankCheck(name: "Concurrent clicks cannot duplicate authentication") { try await ReckonAppLockTests().concurrentClickDoesNotStartAnotherPrompt() },
            BankCheck(name: "Cancelled authentication task keeps data locked") { try await ReckonAppLockTests().cancelledTaskCannotUnlock() },
            BankCheck(name: "Akahu token parsing and redaction") { try backend.akahuCredentialsRejectInvalidTokensAndRedactDescriptions() },
            BankCheck(name: "Bundled backend launch, auth, stop, and restart") { try await backend.startsAuthenticatedBackendAndReleasesItsPort() },
            BankCheck(name: "Missing bundled backend") { try await backend.missingBundleProducesAnActionableFailure() },
            BankCheck(name: "Malformed backend startup response") { try await backend.malformedStartupResponseStopsTheChild() },
            BankCheck(name: "Backend startup cancellation") { try await backend.cancellingStartupStopsTheChild() },
            BankCheck(name: "Unexpected backend exit notification") { try await backend.unexpectedExitNotifiesTheAppAndAllowsRestart() },
            BankCheck(name: "Liquid balance scope and decimal precision") { try dashboard.liquidBalanceExcludesInvestmentsCreditAndForeignCurrency() },
            BankCheck(name: "Negative balance and empty accounts") { try dashboard.negativeBalanceAndNoAccountsRemainHonest() },
            BankCheck(name: "Auckland month and year boundary") { try dashboard.aucklandMonthBoundaryAndYearRollover() },
            BankCheck(name: "Leap day and NZ winter time") { try dashboard.leapDayAndWinterTime() },
            BankCheck(name: "Source timestamp variants") { try dashboard.timestampFormatsAndMissingValues() },
            BankCheck(name: "Missing and multiline tokens fail validation") { try dashboard.rejectsMissingAndMultilineTokens() },
            BankCheck(name: "Three-month comparison and sample data") { try dashboard.trailingAverageUsesThreeFullMonthsIncludingZeroMonths() },
            BankCheck(name: "REST authentication, endpoints, and date queries") { try await api.requestsCorrectRESTEndpointsWithBearerAndNZDateWindows() },
            BankCheck(name: "Partial summary failure retains balances") { try await api.failedSummaryPreservesLiquidBalanceAndOtherStats() },
            BankCheck(name: "Unauthorized accounts fail closed") { try await api.unauthorizedAccountsFailWithoutTreatingThemAsZeroBalance() },
            BankCheck(name: "HTML login page produces an actionable error") { try await api.htmlLoginPageFailsWithAnActionableMessage() }
        ]
        for json in [#""12.34garbage""#, #""NaN""#, #""""#, "12.34", #""1,234.00""#] {
            checks.append(BankCheck(name: "Reject malformed money: \(json)") { try dashboard.malformedMoneyFailsDecoding(json: json) })
        }
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com?token=secret", "https://example.com/#accounts", "file:///tmp/api", "not a url"] {
            checks.append(BankCheck(name: "Reject unsafe URL: \(url)") { try dashboard.rejectsUnsafeConnectionURLs(url: url) })
        }
        for url in ["http://localhost:3001", "http://127.0.0.1:3001", "http://[::1]:3001", "https://api.example.com/api/"] {
            checks.append(BankCheck(name: "Accept API URL: \(url)") { try dashboard.acceptsHTTPSAndLoopbackURLs(url: url) })
        }
        var failed = 0
        for check in checks {
            do {
                try await check.run()
                print("PASS \(check.name)")
            } catch {
                failed += 1
                print("FAIL \(check.name): \(error)")
            }
        }
        print("\(checks.count - failed)/\(checks.count) checks passed")
        if failed > 0 { exit(1) }
    }
}
