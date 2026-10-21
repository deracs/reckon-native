use bigdecimal::{BigDecimal, RoundingMode, Zero};
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::str::FromStr;

/// Bank account identity remains distinct from transaction identity.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Deserialize, Serialize)]
pub(crate) struct AccountId(pub(crate) String);

/// Posted or pending transaction identity used for transfer detection.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize)]
pub(crate) struct TransactionId(pub(crate) String);

/// Money uses decimal arithmetic and is serialized as a normalized decimal string.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Default)]
pub(crate) struct Money(pub(crate) BigDecimal);
impl Money {
    pub(crate) fn rounded(&self) -> Self {
        Self(self.0.with_scale_round(2, RoundingMode::HalfUp))
    }
}
impl Serialize for Money {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0.normalized().to_plain_string())
    }
}
impl<'de> Deserialize<'de> for Money {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum SourceAmount {
            Number(f64),
            Text(String),
        }
        let amount = match SourceAmount::deserialize(deserializer)? {
            SourceAmount::Number(number) => number,
            SourceAmount::Text(text) => text
                .trim()
                .parse::<f64>()
                .map_err(serde::de::Error::custom)?,
        };
        if !amount.is_finite() {
            return Err(serde::de::Error::custom(
                "Akahu money amount must be finite",
            ));
        }
        // Match the original adapter's finite JS-number conversion before decimal arithmetic.
        BigDecimal::from_str(ryu_js::Buffer::new().format(amount))
            .map(Self)
            .map_err(serde::de::Error::custom)
    }
}

/// Account balances retain their own currency, including overdrawn liquid accounts.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BankAccount {
    pub(crate) id: AccountId,
    pub(crate) name: String,
    #[serde(rename = "type")]
    pub(crate) account_type: String,
    pub(crate) currency: String,
    pub(crate) balance: Money,
    pub(crate) available_balance: Option<Money>,
    pub(crate) credit_limit: Option<Money>,
    pub(crate) account_number: Option<String>,
    pub(crate) status: Option<String>,
    pub(crate) bank_name: Option<String>,
    pub(crate) bank_logo: Option<String>,
}
impl BankAccount {
    pub(crate) fn is_liquid_nzd(&self) -> bool {
        self.currency == "NZD" && matches!(self.account_type.as_str(), "checking" | "savings")
    }
}

/// Source kind preserves the established JSON distinction between absent and null metadata.
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum BankTransactionSource {
    Posted,
    Pending,
}

/// Transaction dates are UTC calendar dates; amounts retain the account currency.
#[derive(Clone)]
pub(crate) struct BankTransaction {
    pub(crate) source: BankTransactionSource,
    pub(crate) id: TransactionId,
    pub(crate) account_id: AccountId,
    pub(crate) date: NaiveDate,
    pub(crate) description: String,
    pub(crate) merchant: Option<String>,
    pub(crate) merchant_logo: Option<String>,
    pub(crate) category: Option<String>,
    pub(crate) amount: Money,
    pub(crate) currency: String,
}

impl Serialize for BankTransaction {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(None)?;
        map.serialize_entry("id", &self.id)?;
        map.serialize_entry("accountId", &self.account_id)?;
        map.serialize_entry("date", &self.date)?;
        map.serialize_entry("description", &self.description)?;
        if self.source == BankTransactionSource::Posted {
            map.serialize_entry("merchant", &self.merchant)?;
            map.serialize_entry("merchantLogo", &self.merchant_logo)?;
            map.serialize_entry("category", &self.category)?;
        }
        map.serialize_entry("amount", &self.amount)?;
        map.serialize_entry("currency", &self.currency)?;
        map.end()
    }
}

/// Recurring charges use the established fixed 7/14/30/91-day projection intervals.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RecurringCharge {
    pub(crate) merchant: String,
    pub(crate) category: Option<String>,
    pub(crate) cadence: &'static str,
    pub(crate) occurrences: usize,
    pub(crate) average_amount: Money,
    pub(crate) min_amount: Money,
    pub(crate) max_amount: Money,
    pub(crate) total_spent: Money,
    pub(crate) first_date: NaiveDate,
    pub(crate) last_date: NaiveDate,
    pub(crate) last_amount: Money,
}
impl RecurringCharge {
    pub(crate) fn project_dates(&self, from: NaiveDate, to: NaiveDate) -> Vec<NaiveDate> {
        let interval = match self.cadence {
            "weekly" => 7,
            "fortnightly" => 14,
            "monthly" => 30,
            "quarterly" => 91,
            _ => unreachable!("Bank cadence was not classified"),
        };
        let mut dates = Vec::new();
        let mut next = self.last_date + chrono::Duration::days(interval);
        while next <= to {
            if next >= from {
                dates.push(next);
            }
            next += chrono::Duration::days(interval);
        }
        dates
    }
}

/// Data freshness preserves source timestamps independently for each account.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AccountFreshness {
    pub(crate) account_id: AccountId,
    pub(crate) account_name: String,
    pub(crate) balance_refreshed_at: Option<String>,
    pub(crate) transactions_refreshed_at: Option<String>,
    pub(crate) party_refreshed_at: Option<String>,
    pub(crate) meta_refreshed_at: Option<String>,
}

pub(crate) fn format_source_time(time: Option<DateTime<Utc>>) -> Option<String> {
    time.map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}

pub(crate) fn zero_money() -> BigDecimal {
    BigDecimal::zero()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_money_rejects_nonfinite_and_preserves_finite_decimal_strings() {
        for raw in [
            "\"NaN\"",
            "\"Infinity\"",
            "\"-Infinity\"",
            "\"1e309\"",
            "null",
            "true",
        ] {
            assert!(serde_json::from_str::<Money>(raw).is_err());
        }
        for (raw, expected) in [
            ("\"-12.50\"", "-12.5"),
            ("0", "0"),
            ("\"250.75\"", "250.75"),
        ] {
            assert_eq!(
                serde_json::to_value(serde_json::from_str::<Money>(raw).unwrap()).unwrap(),
                expected
            );
        }
    }
}
