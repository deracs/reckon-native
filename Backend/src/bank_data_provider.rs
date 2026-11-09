use crate::bank_models::{AccountFreshness, BankAccount, BankTransaction};
use chrono::NaiveDate;
use std::ops::RangeInclusive;
use std::sync::Arc;

/// Safe failure tags never contain request URLs, credentials, or source bodies.
#[derive(Debug)]
pub(crate) enum BankReadError {
    Transport,
    Http,
    Decode,
    Timeout,
}

/// A provider supplies normalized banking data to shared request handling.
/// Dropping a read must cancel its outstanding work. Snapshot IDs identify
/// related dashboard reads; providers may share their storage and source reads.
pub(crate) trait BankDataProvider {
    async fn list_bank_accounts(&self) -> Result<Vec<BankAccount>, BankReadError>;
    async fn list_account_freshness(&self) -> Result<Vec<AccountFreshness>, BankReadError>;
    /// Dates are inclusive; absent bounds retain the provider's current defaults.
    async fn fetch_bank_transactions(
        &self,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        snapshot: Option<&str>,
    ) -> Result<BankTransactionView, BankReadError>;
}

/// Shared snapshot storage allows transaction views to borrow records without copying.
pub(crate) struct BankSnapshot {
    pub(crate) from: NaiveDate,
    pub(crate) to: NaiveDate,
    pub(crate) transactions: Vec<BankTransaction>,
}

/// A transaction view retains shared storage and an optional inclusive date filter.
pub(crate) struct BankTransactionView {
    pub(crate) snapshot: Arc<BankSnapshot>,
    pub(crate) range: Option<RangeInclusive<NaiveDate>>,
}
impl BankTransactionView {
    /// Direct reads may retain pending rows outside the posted transaction range.
    pub(crate) fn iter(&self) -> impl Iterator<Item = &BankTransaction> {
        self.snapshot.transactions.iter().filter(|transaction| {
            self.range
                .as_ref()
                .is_none_or(|range| range.contains(&transaction.date))
        })
    }
}
