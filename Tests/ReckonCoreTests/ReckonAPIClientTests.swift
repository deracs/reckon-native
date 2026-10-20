import Foundation
import ReckonCore

private final class BankRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func reset() { lock.withLock { requests = [] } }
    func snapshot() -> [URLRequest] { lock.withLock { requests } }
}

private final class BankFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let log = BankRequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.append(request)
        guard let url = request.url else { return }
        let status = url.host == "unauthorized.invalid" ? 401
            : url.host == "partial.invalid" && url.lastPathComponent == "recurring" ? 503 : 200
        let body: String
        switch url.lastPathComponent {
        case "accounts": body = url.host == "bad-payload.invalid" ? "<html>Sign in</html>" : #"[{"id":"a1","name":"Main","type":"checking","currency":"NZD","balance":"123.45"}]"#
        case "cashflow": body = #"[{"month":"2026-10","income":"5000.00","spending":"2000.25","net":"2999.75","transactionCount":20}]"#
        case "spending": body = #"[{"category":"Groceries","spent":"200.25","transactionCount":4}]"#
        case "recurring": body = #"[{"merchant":"Rent","cadence":"weekly","occurrences":20,"averageAmount":"500.00","lastDate":"2026-10-19"}]"#
        case "transactions": body = #"[{"id":"t1","accountId":"a1","date":"2026-10-20","description":"Grocer","merchantLogo":"https://cdn.akahu.nz/logo.png","amount":"-12.30","currency":"NZD"}]"#
        case "forecast": body = #"{"startDate":"2026-10-20","endDate":"2026-11-19","startingBalance":"123.45","endingBalance":"100.00","points":[],"events":[],"risks":[]}"#
        case "freshness": body = #"[{"accountId":"a1","accountName":"Main","balanceRefreshedAt":"2026-10-20T01:00:00.000Z"}]"#
        default: body = "[]"
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ReckonAPIClientTests: Sendable {
    private func client(host: String = "bank.invalid") throws -> ReckonAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BankFixtureProtocol.self]
        return ReckonAPIClient(connection: try ReckonConnection(baseURL: "https://\(host)/api/", token: "rest-test-token"),
                               session: URLSession(configuration: configuration))
    }

    func requestsCorrectRESTEndpointsWithBearerAndNZDateWindows() async throws {
        BankFixtureProtocol.log.reset()
        let now = try bankRequire(ISO8601DateFormatter().date(from: "2026-10-20T01:00:00Z"))
        let apiClient = try client()
        let dashboard = try await apiClient.fetchDashboard(now: now)
        try bankExpect(dashboard.liquidBalance == Decimal(string: "123.45"))
        try bankExpect(dashboard.currentCashflow?.net.value == Decimal(string: "2999.75"))
        try bankExpect(dashboard.transactions.value?.first?.logoURL?.host == "cdn.akahu.nz")
        try bankExpect(dashboard.forecast.value?.startingBalance.value == Decimal(string: "123.45"))
        let requests = BankFixtureProtocol.log.snapshot()
        try bankExpect(requests.count == 8)
        let snapshotIDs = Set(requests.compactMap { $0.value(forHTTPHeaderField: "X-Reckon-Snapshot") })
        try bankExpect(snapshotIDs.count == 1)
        try bankExpect(snapshotIDs.first.flatMap(UUID.init(uuidString:)) != nil)
        for request in requests {
            try bankExpect(request.httpMethod == "GET")
            try bankExpect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rest-test-token")
            try bankExpect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            try bankExpect(request.url?.path.hasPrefix("/api/") == true)
            try bankExpect(request.url?.path != "/api/refresh")
        }
        let spendingQueries = requests.filter { $0.url?.lastPathComponent == "spending" }.compactMap { request -> [String: String]? in
            guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        try bankExpect(spendingQueries.contains(["from": "2026-10-01", "to": "2026-10-20", "excludeTransfers": "true"]))
        try bankExpect(spendingQueries.contains(["from": "2026-07-01", "to": "2026-09-30", "excludeTransfers": "true"]))
        let transactionsURL = try bankRequire(requests.first { $0.url?.lastPathComponent == "transactions" }?.url)
        let transactionQuery = URLComponents(url: transactionsURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try bankExpect(transactionQuery.contains(URLQueryItem(name: "limit", value: "100")))
        try bankExpect(transactionQuery.contains(URLQueryItem(name: "excludeTransfers", value: "true")))
        let forecastURL = try bankRequire(requests.first { $0.url?.lastPathComponent == "forecast" }?.url)
        try bankExpect(URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "days", value: "30")) == true)
        let recurring = try bankRequire(requests.first { $0.url?.lastPathComponent == "recurring" }?.url)
        let recurringQuery = URLComponents(url: recurring, resolvingAgainstBaseURL: false)?.queryItems
        try bankExpect(recurringQuery?.contains(URLQueryItem(name: "from", value: "2026-04-20")) == true)

        BankFixtureProtocol.log.reset()
        _ = try await apiClient.fetchDashboard(now: now)
        let nextRequests = BankFixtureProtocol.log.snapshot()
        try bankExpect(nextRequests.count == 8)
        let nextSnapshotIDs = Set(nextRequests.compactMap { $0.value(forHTTPHeaderField: "X-Reckon-Snapshot") })
        try bankExpect(nextSnapshotIDs.count == 1 && nextSnapshotIDs != snapshotIDs)
    }

    func failedSummaryPreservesLiquidBalanceAndOtherStats() async throws {
        let dashboard = try await client(host: "partial.invalid").fetchDashboard()
        try bankExpect(dashboard.liquidBalance == Decimal(string: "123.45"))
        try bankExpect(dashboard.cashflow.value != nil)
        try bankExpect(dashboard.standingOrders.value == nil)
        try bankExpect(dashboard.standingOrders.errorMessage == "Reckon API returned HTTP 503.")
    }

    func unauthorizedAccountsFailWithoutTreatingThemAsZeroBalance() async throws {
        do {
            _ = try await client(host: "unauthorized.invalid").fetchDashboard()
            throw BankCheckFailure(message: "Expected unauthorized response")
        } catch ReckonAPIError.unauthorized {
        }
    }

    func htmlLoginPageFailsWithAnActionableMessage() async throws {
        do {
            _ = try await client(host: "bad-payload.invalid").fetchDashboard()
            throw BankCheckFailure(message: "Expected invalid response")
        } catch ReckonAPIError.invalidPayload(let path) {
            try bankExpect(path == "/accounts")
        }
    }
}
