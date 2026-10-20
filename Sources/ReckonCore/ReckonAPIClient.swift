import Foundation

public enum ReckonAPIError: LocalizedError, Sendable {
    case invalidURL
    case missingToken
    case unauthorized
    case httpStatus(Int)
    case invalidResponse
    case invalidPayload(String)
    case connectionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Use an HTTPS API URL, or HTTP on localhost. Omit credentials, query strings, and fragments."
        case .missingToken: "Enter the Reckon API bearer token."
        case .unauthorized: "Could not authenticate with Reckon’s local backend. Reload stats to restart it."
        case .httpStatus(500), .httpStatus(502): "Could not read Akahu data. Check your Akahu tokens and bank connections."
        case .httpStatus(let status): "Reckon API returned HTTP \(status)."
        case .invalidResponse: "Reckon API did not return an HTTP response."
        case .invalidPayload(let path): "Reckon’s backend returned unexpected data for \(path). Rebuild the app."
        case .connectionFailed: "Could not reach Reckon’s local backend. Reload stats to restart it."
        }
    }
}

/// The REST token is separate from Reckon's web RPC token and Akahu tokens.
public struct ReckonConnection: Codable, Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: String, token: String) throws {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              let url = components.url,
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw ReckonAPIError.invalidURL
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else { throw ReckonAPIError.missingToken }
        self.baseURL = url
        self.token = token
    }
}

private final class RejectAPIRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ReckonAPIClient: Sendable {
    public let connection: ReckonConnection
    private let session: URLSession

    public init(connection: ReckonConnection, session: URLSession? = nil) {
        self.connection = connection
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 35
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: RejectAPIRedirects(), delegateQueue: nil)
        }
    }

    public func fetchDashboard(now: Date = .now) async throws -> BankDashboard {
        let window = BankDateWindow(now: now)
        let snapshotID = UUID().uuidString
        let currentQuery = window.query(from: window.monthStart, to: window.today) + [URLQueryItem(name: "excludeTransfers", value: "true")]
        let previousQuery = window.query(from: window.previousThreeMonthsStart, to: window.previousMonthEnd) + [URLQueryItem(name: "excludeTransfers", value: "true")]
        let recurringQuery = window.query(from: window.recurringStart, to: window.today)

        async let accounts: [BankAccount] = get("accounts", snapshotID: snapshotID)
        async let cashflow: BankSection<[MonthlyCashflow]> = section("cashflow", query: currentQuery, snapshotID: snapshotID)
        async let spending: BankSection<[CategorySpending]> = section("spending", query: currentQuery, snapshotID: snapshotID)
        async let previousSpending: BankSection<[CategorySpending]> = section("spending", query: previousQuery, snapshotID: snapshotID)
        async let standingOrders: BankSection<[StandingOrder]> = section("recurring", query: recurringQuery, snapshotID: snapshotID)
        async let freshness: BankSection<[AccountFreshness]> = section("freshness", snapshotID: snapshotID)
        async let transactions: BankSection<[BankTransaction]> = section("transactions", query:
            recurringQuery + [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "excludeTransfers", value: "true")], snapshotID: snapshotID)
        async let forecast: BankSection<BankForecast> = section("forecast", query:
            [URLQueryItem(name: "days", value: "30"), URLQueryItem(name: "excludeTransfers", value: "true")], snapshotID: snapshotID)

        return try await BankDashboard(accounts: accounts, cashflow: cashflow, spending: spending,
                                       previousSpending: previousSpending, standingOrders: standingOrders,
                                       freshness: freshness, window: window, fetchedAt: now, transactions: transactions, forecast: forecast)
    }

    private func section<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], snapshotID: String) async -> BankSection<Value> {
        do { return .loaded(try await get(path, query: query, snapshotID: snapshotID)) }
        catch { return .failed(error.localizedDescription) }
    }

    private func get<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], snapshotID: String) async throws -> Value {
        let url = connection.baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ReckonAPIError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else { throw ReckonAPIError.invalidURL }
        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(snapshotID, forHTTPHeaderField: "X-Reckon-Snapshot")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ReckonAPIError.connectionFailed }
        guard let http = response as? HTTPURLResponse else { throw ReckonAPIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw ReckonAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ReckonAPIError.httpStatus(http.statusCode) }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw ReckonAPIError.invalidPayload("/\(path)") }
    }
}
