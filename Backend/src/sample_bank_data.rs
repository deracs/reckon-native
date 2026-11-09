use crate::bank_calendar::bank_today;
use crate::bank_data_provider::{
    BankDataProvider, BankReadError, BankSnapshot, BankTransactionView,
};
use crate::bank_models::{
    AccountFreshness, AccountId, BankAccount, BankTransaction, BankTransactionSource, Money,
    TransactionId,
};
use chrono::{Duration, NaiveDate, Utc};
use std::str::FromStr;
use std::sync::Arc;

/// Fictional local banking data, with no credentials or external requests.
pub(crate) struct SampleBankData {
    snapshot: Arc<BankSnapshot>,
}

impl SampleBankData {
    pub(crate) fn new() -> Self {
        let today = bank_today();
        let mut transactions = Vec::new();
        for week in 0..31 {
            let date = today - Duration::days(week * 7);
            for (account, merchant, category, amount) in [
                ("spending", "Grocer", "Groceries", "-86.40"),
                ("spending", "Corner café", "Cafes", "-6.50"),
                ("savings", "Rent", "Rent", "-600.00"),
            ] {
                transactions.push(sample_transaction(
                    account, merchant, category, amount, date,
                ));
            }
            if week % 2 == 0 {
                transactions.push(sample_transaction(
                    "spending", "Employer", "Income", "3200.00", date,
                ));
            }
        }
        Self {
            snapshot: Arc::new(BankSnapshot {
                from: today - Duration::days(210),
                to: today,
                transactions,
            }),
        }
    }
}

fn sample_transaction(
    account: &str,
    merchant: &str,
    category: &str,
    amount: &str,
    date: NaiveDate,
) -> BankTransaction {
    BankTransaction {
        source: BankTransactionSource::Posted,
        id: TransactionId(format!("sample-{account}-{merchant}-{date}")),
        account_id: AccountId(account.into()),
        date,
        description: merchant.into(),
        merchant: Some(merchant.into()),
        merchant_logo: None,
        category: Some(category.into()),
        amount: Money(
            bigdecimal::BigDecimal::from_str(amount).expect("Sample amounts are valid decimals"),
        ),
        currency: "NZD".into(),
    }
}

fn sample_account(
    id: &str,
    name: &str,
    account_type: &str,
    balance: &str,
    bank: &str,
) -> BankAccount {
    BankAccount {
        id: AccountId(id.into()),
        name: name.into(),
        account_type: account_type.into(),
        currency: "NZD".into(),
        balance: Money(
            bigdecimal::BigDecimal::from_str(balance).expect("Sample balances are valid decimals"),
        ),
        available_balance: None,
        credit_limit: None,
        account_number: None,
        status: Some("active".into()),
        bank_name: Some(bank.into()),
        bank_logo: None,
    }
}

impl BankDataProvider for SampleBankData {
    async fn list_bank_accounts(&self) -> Result<Vec<BankAccount>, BankReadError> {
        Ok(vec![
            sample_account("spending", "Everyday", "checking", "2480.45", "Sample Bank"),
            sample_account("savings", "Rainy day", "savings", "10000.00", "Sample Bank"),
            sample_account(
                "investment",
                "Long term",
                "investment",
                "28400.25",
                "Sample Investments",
            ),
        ])
    }

    async fn list_account_freshness(&self) -> Result<Vec<AccountFreshness>, BankReadError> {
        let timestamp = Some((Utc::now() - Duration::hours(1)).to_rfc3339());
        Ok(self
            .list_bank_accounts()
            .await?
            .into_iter()
            .map(|account| AccountFreshness {
                account_id: account.id,
                account_name: account.name,
                balance_refreshed_at: timestamp.clone(),
                transactions_refreshed_at: timestamp.clone(),
                party_refreshed_at: None,
                meta_refreshed_at: None,
            })
            .collect())
    }

    async fn fetch_bank_transactions(
        &self,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        _snapshot: Option<&str>,
    ) -> Result<BankTransactionView, BankReadError> {
        Ok(BankTransactionView {
            snapshot: Arc::clone(&self.snapshot),
            range: Some(from.unwrap_or(self.snapshot.from)..=to.unwrap_or(self.snapshot.to)),
        })
    }
}
