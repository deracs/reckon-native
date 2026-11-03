import Foundation
import ReckonCore

struct BankActivityFilterTests {
    private func fixture() throws -> ([BankAccount], [BankTransaction]) {
        let decoder = JSONDecoder()
        let accounts = try decoder.decode([BankAccount].self, from: Data(#"[{"id":"daily-a","name":"Everyday","type":"checking","currency":"NZD","balance":"12.34","bankName":" Sample Bank "},{"id":"wallet-b","name":"Travel wallet","type":"checking","currency":"USD","balance":"50.00","bankName":"Another Bank"},{"id":"unknown-c","name":"Unlinked","type":"savings","currency":"NZD","balance":"20.00"}]"#.utf8))
        let transactions = try decoder.decode([BankTransaction].self, from: Data(#"[{"id":"fixture-one","accountId":"daily-a","date":"2026-11-03","description":"Card purchase","merchant":"Corner café","category":"Cafes","amount":"-6.50","currency":"NZD"},{"id":"fixture-two","accountId":"wallet-b","date":"2026-11-02","description":"Trip ticket","merchant":"Rail","category":"Travel","amount":"-10.20","currency":"USD"},{"id":"fixture-three","accountId":"unknown-c","date":"2026-11-01","description":"Transfer refund","amount":"1.00","currency":"NZD"},{"id":"fixture-orphan","accountId":"removed-account","date":"2026-10-31","description":"Older merchant","amount":"-2.00","currency":"NZD"}]"#.utf8))
        return (accounts, transactions)
    }

    func bankAndAccountFiltersIntersectWithoutLeakingOtherBanks() throws {
        let (accounts, rows) = try fixture()
        try bankExpect(BankActivityFilter(bankID: "Sample Bank").apply(to: rows, accounts: accounts).map(\.id) == ["fixture-one"])
        try bankExpect(BankActivityFilter(accountID: "wallet-b").apply(to: rows, accounts: accounts).map(\.id) == ["fixture-two"])
        try bankExpect(BankActivityFilter(bankID: "Sample Bank", accountID: "wallet-b").apply(to: rows, accounts: accounts).isEmpty)
        try bankExpect(BankActivityFilter(bankID: "").apply(to: rows, accounts: accounts).map(\.id) == ["fixture-three"])
    }

    func searchIncludesMerchantDescriptionCategoryBankAccountAndCurrency() throws {
        let (accounts, rows) = try fixture()
        for query in ["corner", "CARD PURCHASE", "cafes", "everyday", "sample bank"] {
            try bankExpect(BankActivityFilter(search: query).apply(to: rows, accounts: accounts).map(\.id) == ["fixture-one"])
        }
        for query in ["  usd \n", "travel wallet", "another bank", "trip ticket"] {
            try bankExpect(BankActivityFilter(search: query).apply(to: rows, accounts: accounts).map(\.id) == ["fixture-two"])
        }
    }

    func emptySearchRetainsPageOrderMoneyCurrencyAndOrphanedRows() throws {
        let (accounts, rows) = try fixture()
        let result = BankActivityFilter(search: "  ").apply(to: rows, accounts: accounts)
        try bankExpect(result.map(\.id) == rows.map(\.id))
        try bankExpect(result[1].currency == "USD")
        try bankExpect(result[1].amount.value == Decimal(string: "-10.20"))
        try bankExpect(BankActivityFilter(search: "older merchant").apply(to: rows, accounts: accounts).map(\.id) == ["fixture-orphan"])
    }
}
