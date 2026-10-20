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
        try FileManager.default.createSymbolicLink(at: helpers.appendingPathComponent("node"), withDestinationURL: appBundle.appendingPathComponent("Contents/Helpers/node"))
        try script.write(to: resources.appendingPathComponent("backend.cjs"), atomically: true, encoding: .utf8)
        return folder
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
