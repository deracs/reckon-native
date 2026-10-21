import Darwin
import Foundation
import Security

public enum BundledBackendError: LocalizedError, Equatable, Sendable {
    case missingResources
    case launchFailed
    case startupFailed
    case startupTimedOut
    case unexpectedExit
    case invalidProtocol
    case randomnessUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingResources: "The bundled backend is missing. Rebuild Reckon with scripts/build-app.sh."
        case .launchFailed: "Could not start Reckon’s bundled backend. Rebuild the app and try again."
        case .startupFailed: "Reckon’s bundled backend could not start. Check your Akahu settings."
        case .startupTimedOut: "Reckon’s bundled backend did not start in time. Reload stats to try again."
        case .unexpectedExit: "Reckon’s bundled backend stopped. Reload stats to restart it."
        case .invalidProtocol: "Reckon’s bundled backend returned an invalid startup response. Rebuild the app."
        case .randomnessUnavailable: "Could not create a private token for Reckon’s local API."
        }
    }
}

private enum BackendEvent: Decodable {
    case ready(port: Int)
    case failed

    private enum CodingKeys: String, CodingKey { case event, port }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .event) {
        case "ready":
            let port = try values.decode(Int.self, forKey: .port)
            guard (1...65535).contains(port) else { throw BundledBackendError.invalidProtocol }
            self = .ready(port: port)
        case "failed": self = .failed
        default: throw BundledBackendError.invalidProtocol
        }
    }
}

@MainActor
private final class BackendChild {
    let id = UUID()
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let apiToken: String
    var received = Data()
    var startupTimeout: Task<Void, Never>?

    init(apiToken: String) { self.apiToken = apiToken }
}

/// Owns a bundled Rust child and its authenticated loopback API; dashboard refreshes scope its lifetime.
@MainActor
public final class BundledBackend {
    public var onUnexpectedExit: ((BundledBackendError) -> Void)?

    private enum State {
        case stopped
        case starting(BackendChild, CheckedContinuation<ReckonConnection, any Error>)
        case running(BackendChild, ReckonConnection)
    }

    private let bundleURL: URL
    private var state = State.stopped

    public init(bundleURL: URL) { self.bundleURL = bundleURL }

    /// Fetches one dashboard and releases the backend process on success, failure, or cancellation.
    public static func fetchDashboard(bundleURL: URL, credentials: AkahuCredentials) async throws -> BankDashboard {
        let backend = BundledBackend(bundleURL: bundleURL)
        defer { backend.stop() }
        let connection = try await backend.start(credentials: credentials)
        let client = ReckonAPIClient(connection: connection)
        defer { client.invalidateSession() }
        let dashboard = try await client.fetchDashboard()
        try Task.checkCancellation()
        guard backend.isRunning else { throw BundledBackendError.unexpectedExit }
        return dashboard
    }

    public var isRunning: Bool {
        if case .running(let child, _) = state { return child.process.isRunning }
        return false
    }

    public func start(credentials: AkahuCredentials) async throws -> ReckonConnection {
        stop()
        try Task.checkCancellation()
        let executable = bundleURL.appendingPathComponent("Contents/Helpers/reckon-backend")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw BundledBackendError.missingResources }
        var randomBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else {
            throw BundledBackendError.randomnessUnavailable
        }
        let child = BackendChild(apiToken: randomBytes.map { String(format: "%02x", $0) }.joined())
        child.process.executableURL = executable
        child.process.arguments = []
        child.process.currentDirectoryURL = executable.deletingLastPathComponent()
        child.process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_NZ.UTF-8", "TZ": "Pacific/Auckland"]
        child.process.standardInput = child.input
        child.process.standardOutput = child.output
        child.process.standardError = FileHandle.nullDevice
        _ = fcntl(child.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let id = child.id
        let outputDescriptor = child.output.fileHandleForReading.fileDescriptor
        let outputFlags = fcntl(outputDescriptor, F_GETFL)
        _ = fcntl(outputDescriptor, F_SETFL, outputFlags | O_NONBLOCK)
        child.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { read(outputDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            let data = count > 0 ? Data(bytes.prefix(count)) : Data()
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.receiveOutput(data, from: id) }
        }
        child.process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.processExited(id) }
        }

        struct Handshake: Encodable {
            let appToken: String
            let userToken: String
            let apiToken: String
        }
        var input = try JSONEncoder().encode(Handshake(appToken: credentials.appToken, userToken: credentials.userToken, apiToken: child.apiToken))
        input.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state = .starting(child, continuation)
                do {
                    try child.process.run()
                    try child.input.fileHandleForReading.close()
                    try child.output.fileHandleForWriting.close()
                    try child.input.fileHandleForWriting.write(contentsOf: input)
                    child.startupTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(12)) }
                        catch { return }
                        self?.failStartup(id, error: .startupTimedOut)
                    }
                } catch {
                    failStartup(id, error: .launchFailed)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelStartup(id) }
        }
    }

    public func stop() {
        let child: BackendChild
        switch state {
        case .stopped: return
        case .starting(let starting, let continuation):
            child = starting
            continuation.resume(throwing: CancellationError())
        case .running(let running, _): child = running
        }
        state = .stopped
        releaseProcess(child)
    }

    private func receiveOutput(_ data: Data, from id: UUID) {
        guard case .starting(let child, let continuation) = state, child.id == id else { return }
        guard !data.isEmpty else { return }
        child.received.append(data)
        guard child.received.count <= 16_384 else { failStartup(id, error: .invalidProtocol); return }
        guard let newline = child.received.firstIndex(of: 0x0A) else { return }
        do {
            switch try JSONDecoder().decode(BackendEvent.self, from: child.received[..<newline]) {
            case .ready(let port):
                let connection = try ReckonConnection(baseURL: "http://127.0.0.1:\(port)", token: child.apiToken)
                child.startupTimeout?.cancel()
                child.received.removeAll()
                state = .running(child, connection)
                continuation.resume(returning: connection)
            case .failed: failStartup(id, error: .startupFailed)
            }
        } catch { failStartup(id, error: .invalidProtocol) }
    }

    private func processExited(_ id: UUID) {
        switch state {
        case .starting(let child, _) where child.id == id: failStartup(id, error: .startupFailed)
        case .running(let child, _) where child.id == id:
            state = .stopped
            releaseProcess(child)
            onUnexpectedExit?(.unexpectedExit)
        default: break
        }
    }

    private func failStartup(_ id: UUID, error: BundledBackendError) {
        guard case .starting(let child, let continuation) = state, child.id == id else { return }
        state = .stopped
        releaseProcess(child)
        continuation.resume(throwing: error)
    }

    private func cancelStartup(_ id: UUID) {
        guard case .starting(let child, _) = state, child.id == id else { return }
        stop()
    }

    private func releaseProcess(_ child: BackendChild) {
        child.startupTimeout?.cancel()
        child.output.fileHandleForReading.readabilityHandler = nil
        child.process.terminationHandler = nil
        try? child.input.fileHandleForWriting.close()
        try? child.output.fileHandleForReading.close()
        if child.process.isRunning {
            child.process.terminate()
            Task {
                try? await Task.sleep(for: .seconds(3))
                if child.process.isRunning { kill(child.process.processIdentifier, SIGKILL) }
            }
        }
    }
}
