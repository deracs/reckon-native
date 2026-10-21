import Darwin
import Foundation
import ReckonCore

struct BundledBackendTests: Sendable {
    private var appBundle: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist/Reckon.app")
    }

    func akahuCredentialsRejectInvalidTokensAndRedactDescriptions() throws {
        for token in ["", " ", "app token", "app\ntoken", "app\ttoken", String(repeating: "a", count: 4097), "non-ascii-é"] {
            try bankExpectError { _ = try AkahuCredentials(appToken: token, userToken: "fixture-user") }
            try bankExpectError { _ = try AkahuCredentials(appToken: "fixture-app", userToken: token) }
        }
        let credentials = try AkahuCredentials(appToken: " fixture-app ", userToken: " fixture-user ")
        try bankExpect(credentials.appToken == "fixture-app")
        try bankExpect(!String(describing: credentials).contains("fixture-app"))
        try bankExpect(!String(reflecting: credentials).contains("fixture-user"))
    }

    @MainActor func startsAuthenticatedBackendAndReleasesItsPort() async throws {
        let backend = BundledBackend(bundleURL: appBundle)
        defer { backend.stop() }
        let credentials = try AkahuCredentials(appToken: "fixture-app", userToken: "fixture-user")
        let first = try await backend.start(credentials: credentials)
        try bankExpect(backend.isRunning)
        try bankExpect(first.baseURL.host == "127.0.0.1")
        try bankExpect(first.token.count == 64)
        var request = URLRequest(url: first.baseURL.appendingPathComponent("health"))
        request.setValue("Bearer \(first.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        try bankExpect((response as? HTTPURLResponse)?.statusCode == 200)
        let healthURL = try bankRequire(request.url)
        let (_, unauthenticated) = try await URLSession.shared.data(from: healthURL)
        try bankExpect((unauthenticated as? HTTPURLResponse)?.statusCode == 401)
        backend.stop()
        try bankExpect(!backend.isRunning)
        var closed = false
        for _ in 0..<40 {
            do { _ = try await URLSession.shared.data(for: request) }
            catch { closed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try bankExpect(closed)
        let second = try await backend.start(credentials: credentials)
        try bankExpect(second.token != first.token)
        try bankExpect(backend.isRunning)
    }

    @MainActor func missingBundleProducesAnActionableFailure() async throws {
        let backend = BundledBackend(bundleURL: appBundle.appendingPathComponent("missing-bundle"))
        do {
            _ = try await backend.start(credentials: AkahuCredentials(appToken: "fixture-app", userToken: "fixture-user"))
            throw BankCheckFailure(message: "Expected missing backend resources")
        } catch BundledBackendError.missingResources {
            try bankExpect(!backend.isRunning)
        }
    }

    @MainActor private func fakeBundle(script: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reckon-check-\(UUID())")
        let helpers = folder.appendingPathComponent("Contents/Helpers")
        let resources = folder.appendingPathComponent("Contents/Resources/Backend")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        // Node is test tooling only: the fake process exercises Swift lifecycle failures.
        let node = URL(fileURLWithPath: "/usr/bin/env")
        let executable = helpers.appendingPathComponent("reckon-backend")
        let fixture = resources.appendingPathComponent("backend.cjs")
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let nodePath = try bankRequire(ProcessInfo.processInfo.environment["RECKON_TEST_NODE"] ?? searchPaths
            .map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) })
        try ("#!/bin/sh\nexec \"\(node.path)\" \"\(nodePath)\" \"\(fixture.path)\"\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        return folder
    }

    @MainActor private func dashboardBundle(accountStatus: Int = 200, holdResponses: Bool = false) throws -> URL {
        try fakeBundle(script: """
        const http = require('node:http')
        const fs = require('node:fs')
        const path = require('node:path')
        const server = http.createServer((request, response) => {
            if (\(holdResponses)) return
            const endpoint = new URL(request.url, 'http://localhost').pathname
            const status = endpoint === '/accounts' ? \(accountStatus) : 200
            const body = endpoint === '/forecast'
                ? {startDate:'2026-10-20',endDate:'2026-11-19',startingBalance:'0',endingBalance:'0',points:[],events:[],risks:[]}
                : []
            response.writeHead(status, {'content-type':'application/json'}).end(JSON.stringify(body))
        })
        process.stdin.once('data', () => server.listen(0, '127.0.0.1', () => {
            fs.writeFileSync(path.join(__dirname, 'child.pid'), String(process.pid))
            process.stdout.write(JSON.stringify({event:'ready',port:server.address().port})+'\\n')
        }))
        """)
    }

    @MainActor private func childPID(in folder: URL) async throws -> Int32 {
        let file = folder.appendingPathComponent("Contents/Resources/Backend/child.pid")
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BankCheckFailure(message: "Dashboard fixture child did not start")
    }

    @MainActor private func expectChildExited(in folder: URL) async throws {
        let pid = try await childPID(in: folder)
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        for _ in 0..<100 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BankCheckFailure(message: "Dashboard backend remained alive after its refresh")
    }

    @MainActor func dashboardRefreshReleasesBackendAfterSuccessFailureAndCancellation() async throws {
        let credentials = try AkahuCredentials(appToken: "fixture-app", userToken: "fixture-user")
        let success = try dashboardBundle()
        defer { try? FileManager.default.removeItem(at: success) }
        let dashboard = try await BundledBackend.fetchDashboard(bundleURL: success, credentials: credentials)
        try bankExpect(dashboard.accounts.isEmpty)
        try bankExpect(dashboard.transactions.value?.isEmpty == true)
        try bankExpect(dashboard.forecast.value != nil)
        try await expectChildExited(in: success)

        let failure = try dashboardBundle(accountStatus: 401)
        defer { try? FileManager.default.removeItem(at: failure) }
        do {
            _ = try await BundledBackend.fetchDashboard(bundleURL: failure, credentials: credentials)
            throw BankCheckFailure(message: "Expected unauthorized dashboard failure")
        } catch ReckonAPIError.unauthorized {}
        try await expectChildExited(in: failure)

        let cancelled = try dashboardBundle(holdResponses: true)
        defer { try? FileManager.default.removeItem(at: cancelled) }
        let refresh = Task { try await BundledBackend.fetchDashboard(bundleURL: cancelled, credentials: credentials) }
        _ = try await childPID(in: cancelled)
        refresh.cancel()
        do {
            _ = try await refresh.value
            throw BankCheckFailure(message: "Expected cancelled dashboard refresh")
        } catch is CancellationError {}
        try await expectChildExited(in: cancelled)
    }

    @MainActor func malformedStartupResponseStopsTheChild() async throws {
        let folder = try fakeBundle(script: "process.stdout.write('unexpected output\\n'); setInterval(() => {}, 1000)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = BundledBackend(bundleURL: folder)
        defer { backend.stop() }
        do {
            _ = try await backend.start(credentials: AkahuCredentials(appToken: "fixture-app", userToken: "fixture-user"))
            throw BankCheckFailure(message: "Expected invalid startup protocol")
        } catch BundledBackendError.invalidProtocol {
            try bankExpect(!backend.isRunning)
        }
    }

    @MainActor func cancellingStartupStopsTheChild() async throws {
        let folder = try fakeBundle(script: "process.stdin.resume(); setInterval(() => {}, 1000)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = BundledBackend(bundleURL: folder)
        defer { backend.stop() }
        let startup = Task { try await backend.start(credentials: AkahuCredentials(appToken: "fixture-app", userToken: "fixture-user")) }
        try await Task.sleep(for: .milliseconds(50))
        startup.cancel()
        do {
            _ = try await startup.value
            throw BankCheckFailure(message: "Expected cancelled startup")
        } catch is CancellationError {
            try bankExpect(!backend.isRunning)
        }
    }

    @MainActor func unexpectedExitNotifiesTheAppAndAllowsRestart() async throws {
        let folder = try fakeBundle(script: "process.stdout.write(JSON.stringify({event:'ready',port:12345})+'\\n'); setTimeout(() => process.exit(1), 100)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = BundledBackend(bundleURL: folder)
        defer { backend.stop() }
        var failure: BundledBackendError?
        backend.onUnexpectedExit = { failure = $0 }
        _ = try await backend.start(credentials: AkahuCredentials(appToken: "fixture-app", userToken: "fixture-user"))
        for _ in 0..<40 {
            if failure != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try bankExpect(failure == .unexpectedExit)
        try bankExpect(!backend.isRunning)
    }
}
