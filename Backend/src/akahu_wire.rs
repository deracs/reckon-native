use crate::bank_models::{
    AccountFreshness, AccountId, BankAccount, BankTransaction, BankTransactionSource, Money,
    TransactionId, format_source_time,
};
use bigdecimal::ToPrimitive;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer};

// Akahu optional fields may be absent, but an explicit null is not a valid field value.
fn optional_source_field<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Option<T>, D::Error> {
    T::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
struct SourceBalance {
    current: Money,
    currency: String,
    #[serde(default, deserialize_with = "optional_source_field")]
    available: Option<Money>,
    #[serde(default, deserialize_with = "optional_source_field")]
    limit: Option<Money>,
}
#[derive(Deserialize)]
struct SourceConnection {
    #[serde(rename = "_id")]
    _id: String,
    name: String,
    #[serde(default, deserialize_with = "optional_source_field")]
    logo: Option<String>,
}
#[derive(Default, Deserialize)]
struct SourceRefreshed {
    #[serde(default, deserialize_with = "optional_source_field")]
    balance: Option<DateTime<Utc>>,
    #[serde(default, deserialize_with = "optional_source_field")]
    transactions: Option<DateTime<Utc>>,
    #[serde(default, deserialize_with = "optional_source_field")]
    party: Option<DateTime<Utc>>,
    #[serde(default, deserialize_with = "optional_source_field")]
    meta: Option<DateTime<Utc>>,
}

/// Source account metadata is projected before it reaches bank calculations.
#[derive(Deserialize)]
pub(crate) struct AkahuAccount {
    #[serde(rename = "_id")]
    id: AccountId,
    name: String,
    #[serde(default, deserialize_with = "optional_source_field")]
    status: Option<String>,
    #[serde(rename = "type", default, deserialize_with = "optional_source_field")]
    account_type: Option<String>,
    #[serde(default, deserialize_with = "optional_source_field")]
    formatted_account: Option<String>,
    #[serde(default, deserialize_with = "optional_source_field")]
    balance: Option<SourceBalance>,
    #[serde(default, deserialize_with = "optional_source_field")]
    refreshed: Option<SourceRefreshed>,
    #[serde(default, deserialize_with = "optional_source_field")]
    connection: Option<SourceConnection>,
    #[serde(
        rename = "attributes",
        default,
        deserialize_with = "optional_source_field"
    )]
    _attributes: Option<Vec<String>>,
}
impl AkahuAccount {
    pub(crate) fn account_id(&self) -> &str {
        &self.id.0
    }
    pub(crate) fn currency(&self) -> &str {
        self.balance
            .as_ref()
            .map_or("NZD", |balance| &balance.currency)
    }
    pub(crate) fn to_bank_account(&self) -> BankAccount {
        let account_type = match self.account_type.as_deref() {
            Some("SAVINGS") => "savings",
            Some("CREDITCARD") => "credit",
            Some("LOAN") => "loan",
            Some("KIWISAVER" | "INVESTMENT" | "TERMDEPOSIT") => "investment",
            _ => "checking",
        };
        BankAccount {
            id: self.id.clone(),
            name: self.name.clone(),
            account_type: account_type.to_string(),
            currency: self.currency().to_string(),
            balance: self
                .balance
                .as_ref()
                .map_or_else(Money::default, |b| b.current.clone()),
            available_balance: self.balance.as_ref().and_then(|b| b.available.clone()),
            credit_limit: self.balance.as_ref().and_then(|b| b.limit.clone()),
            account_number: self.formatted_account.clone(),
            status: match self.status.as_deref() {
                Some("ACTIVE") => Some("active".to_string()),
                Some("INACTIVE") => Some("inactive".to_string()),
                _ => None,
            },
            bank_name: self.connection.as_ref().map(|c| c.name.clone()),
            bank_logo: self.connection.as_ref().and_then(|c| c.logo.clone()),
        }
    }
    pub(crate) fn to_account_freshness(&self) -> AccountFreshness {
        let empty = SourceRefreshed::default();
        let times = self.refreshed.as_ref().unwrap_or(&empty);
        AccountFreshness {
            account_id: self.id.clone(),
            account_name: self.name.clone(),
            balance_refreshed_at: format_source_time(times.balance),
            transactions_refreshed_at: format_source_time(times.transactions),
            party_refreshed_at: format_source_time(times.party),
            meta_refreshed_at: format_source_time(times.meta),
        }
    }
}
#[derive(Deserialize)]
struct SourceMerchant {
    name: String,
}
#[derive(Deserialize)]
struct SourceCategory {
    #[serde(rename = "_id")]
    _id: String,
    name: String,
}
#[derive(Deserialize)]
struct SourceMeta {
    #[serde(default, deserialize_with = "optional_source_field")]
    logo: Option<String>,
}

/// Posted transactions require a source account and ID; timestamps project to UTC dates.
#[derive(Deserialize)]
pub(crate) struct AkahuTransaction {
    #[serde(rename = "_id")]
    id: String,
    #[serde(rename = "_account")]
    account: AccountId,
    date: DateTime<Utc>,
    description: String,
    amount: Money,
    #[serde(default, deserialize_with = "optional_source_field")]
    merchant: Option<SourceMerchant>,
    #[serde(default, deserialize_with = "optional_source_field")]
    category: Option<SourceCategory>,
    #[serde(default, deserialize_with = "optional_source_field")]
    meta: Option<SourceMeta>,
    #[serde(default, deserialize_with = "optional_source_field")]
    _user: Option<String>,
    #[serde(default, deserialize_with = "optional_source_field")]
    _connection: Option<String>,
}
impl AkahuTransaction {
    pub(crate) fn into_bank_transaction(self, currency: &str) -> BankTransaction {
        BankTransaction {
            source: BankTransactionSource::Posted,
            id: TransactionId(self.id),
            account_id: self.account,
            date: self.date.date_naive(),
            description: self.description,
            merchant: self.merchant.map(|m| m.name),
            merchant_logo: self.meta.and_then(|m| m.logo),
            category: self.category.map(|c| c.name),
            amount: self.amount,
            currency: currency.to_string(),
        }
    }
}

/// Pending transaction identity retains the original account/date/description/amount format.
#[derive(Deserialize)]
pub(crate) struct AkahuPendingTransaction {
    #[serde(default, deserialize_with = "optional_source_field")]
    _account: Option<AccountId>,
    #[serde(default, deserialize_with = "optional_source_field")]
    account: Option<AccountId>,
    date: DateTime<Utc>,
    description: String,
    amount: Money,
    #[serde(default, deserialize_with = "optional_source_field")]
    _user: Option<String>,
    #[serde(default, deserialize_with = "optional_source_field")]
    _connection: Option<String>,
    #[serde(
        rename = "connection",
        default,
        deserialize_with = "optional_source_field"
    )]
    _source_connection: Option<String>,
}
impl AkahuPendingTransaction {
    pub(crate) fn into_bank_transaction(self, currency: &str) -> BankTransaction {
        let account = self
            ._account
            .or(self.account)
            .unwrap_or_else(|| AccountId("unknown".to_string()));
        let date = self.date.date_naive();
        BankTransaction {
            source: BankTransactionSource::Pending,
            id: TransactionId(format!(
                "pending:{}:{}:{}:{}",
                account.0,
                date,
                self.description,
                ryu_js::Buffer::new().format(
                    self.amount
                        .0
                        .to_f64()
                        .expect("Source amount is a finite f64")
                )
            )),
            account_id: account,
            date,
            description: self.description,
            merchant: None,
            merchant_logo: None,
            category: None,
            amount: self.amount,
            currency: currency.to_string(),
        }
    }
}

/// A missing or null next cursor ends a source page stream.
#[derive(Deserialize)]
pub(crate) struct AkahuCursor {
    pub(crate) next: Option<String>,
}

/// The page envelope validates source success and item types before cache insertion.
#[derive(Deserialize)]
pub(crate) struct AkahuPage<T> {
    #[serde(rename = "success")]
    _success: bool,
    pub(crate) items: Vec<T>,
    #[serde(default, deserialize_with = "optional_source_field")]
    pub(crate) cursor: Option<AkahuCursor>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_pages_decode_the_local_akahu_fixture() {
        let page = serde_json::json!({"success":true,"items":[{"_id":"acc_main","name":"Everyday","type":"CHECKING","balance":{"current":123.45,"currency":"NZD"},"status":"ACTIVE","refreshed":{"balance":"2026-10-20T00:00:00Z","transactions":"2026-10-20T00:00:00Z"}}],"cursor":{"next":"second-page"}});
        let decoded: AkahuPage<AkahuAccount> = serde_json::from_value(page).unwrap();
        assert_eq!(decoded.items.len(), 1);
    }
}
