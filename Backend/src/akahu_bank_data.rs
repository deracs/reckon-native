use crate::akahu_wire::{AkahuAccount, AkahuPage, AkahuPendingTransaction, AkahuTransaction};
use crate::backend_handshake::BackendHandshake;
use crate::bank_calendar::{add_bank_months, bank_today};
use crate::bank_models::BankTransaction;
use chrono::{Datelike, Duration as BankDuration, NaiveDate, Utc};
use futures_util::{StreamExt, TryStreamExt, stream};
use reqwest::{Client, StatusCode};
use serde::de::DeserializeOwned;
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// Safe failure tags never contain request URLs, credentials, or source bodies.
#[derive(Debug)]
pub(crate) enum BankReadError {
    Transport,
    Http,
    Decode,
    Timeout,
}

// Match encodeURIComponent so source account IDs retain Akahu's path spelling.
const AKAHU_ACCOUNT_PATH: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'_')
    .remove(b'-')
    .remove(b'.')
    .remove(b'!')
    .remove(b'~')
    .remove(b'*')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')');

type BankCache<T> = Mutex<Option<(Instant, Arc<T>)>>;
struct BankSnapshot {
    from: NaiveDate,
    to: NaiveDate,
    transactions: Vec<BankTransaction>,
}
type SnapshotSlot = Arc<BankCache<BankSnapshot>>;

/// A transaction view retains shared snapshot storage while iterators borrow its records.
pub(crate) struct BankTransactionView {
    snapshot: Arc<BankSnapshot>,
    range: Option<std::ops::RangeInclusive<NaiveDate>>,
}
impl BankTransactionView {
    /// Borrow records in the requested range; direct source reads preserve pending-row behavior.
    pub(crate) fn iter(&self) -> impl Iterator<Item = &BankTransaction> {
        self.snapshot.transactions.iter().filter(|transaction| {
            self.range
                .as_ref()
                .is_none_or(|range| range.contains(&transaction.date))
        })
    }
}

/// Akahu reads own pagination, bounded retries and cancellable single-flight caches.
pub(crate) struct AkahuBankData {
    client: Client,
    base_url: String,
    accounts: BankCache<Vec<AkahuAccount>>,
    snapshots: Mutex<VecDeque<(String, SnapshotSlot)>>,
}
impl AkahuBankData {
    pub(crate) fn new(handshake: &BackendHandshake) -> Result<Self, BankReadError> {
        let mut headers = reqwest::header::HeaderMap::new();
        let mut app = handshake
            .app_token
            .expose()
            .parse::<reqwest::header::HeaderValue>()
            .map_err(|_| BankReadError::Transport)?;
        app.set_sensitive(true);
        headers.insert("x-akahu-id", app);
        let mut user = format!("Bearer {}", handshake.user_token.expose())
            .parse::<reqwest::header::HeaderValue>()
            .map_err(|_| BankReadError::Transport)?;
        user.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, user);
        headers.insert(
            reqwest::header::ACCEPT,
            reqwest::header::HeaderValue::from_static("application/json"),
        );
        let client = Client::builder()
            .default_headers(headers)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .map_err(|_| BankReadError::Transport)?;
        Ok(Self {
            client,
            base_url: handshake.akahu_base_url.trim_end_matches('/').to_string(),
            accounts: Mutex::new(None),
            snapshots: Mutex::new(VecDeque::new()),
        })
    }
    async fn read_page<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(String, String)],
    ) -> Result<AkahuPage<T>, BankReadError> {
        tokio::time::timeout(Duration::from_secs(20), async {
            for attempt in 0..=5 {
                let response = self
                    .client
                    .get(format!("{}{path}", self.base_url))
                    .query(query)
                    .send()
                    .await;
                let delay = match response {
                    Ok(response) if response.status().is_success() => {
                        return response.json().await.map_err(|_| BankReadError::Decode);
                    }
                    Ok(response) => {
                        let retryable = matches!(
                            response.status(),
                            StatusCode::REQUEST_TIMEOUT
                                | StatusCode::TOO_MANY_REQUESTS
                                | StatusCode::INTERNAL_SERVER_ERROR
                                | StatusCode::BAD_GATEWAY
                                | StatusCode::SERVICE_UNAVAILABLE
                                | StatusCode::GATEWAY_TIMEOUT
                        );
                        if !retryable || attempt == 5 {
                            return Err(BankReadError::Http);
                        }
                        response
                            .headers()
                            .get(reqwest::header::RETRY_AFTER)
                            .and_then(|v| v.to_str().ok())
                            .and_then(|s| {
                                s.parse::<f64>()
                                    .ok()
                                    .filter(|n| n.is_finite() && *n >= 0.)
                                    .map(|seconds| Duration::from_secs_f64(seconds.min(20.)))
                                    .or_else(|| {
                                        chrono::DateTime::parse_from_rfc2822(s).ok().map(|date| {
                                            (date.with_timezone(&Utc) - Utc::now())
                                                .to_std()
                                                .unwrap_or_default()
                                        })
                                    })
                            })
                    }
                    Err(_) if attempt == 5 => return Err(BankReadError::Transport),
                    Err(_) => None,
                };
                // Retry jitter needs no persistent RNG state or worker pool. OS read failures
                // use the low end of the jitter range; no credential depends on this byte.
                use std::io::Read;
                let mut entropy = [0u8; 1];
                if std::fs::File::open("/dev/urandom")
                    .and_then(|mut source| source.read_exact(&mut entropy))
                    .is_err()
                {
                    entropy[0] = 0;
                }
                let backoff = Duration::from_secs_f64(
                    0.5 * 2f64.powi(attempt) * (0.8 + 0.4 * f64::from(entropy[0]) / 255.),
                );
                tokio::time::sleep(delay.unwrap_or(backoff).min(Duration::from_secs(20))).await;
            }
            Err(BankReadError::Transport)
        })
        .await
        .map_err(|_| BankReadError::Timeout)?
    }
    async fn list_pages<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(String, String)],
    ) -> Result<Vec<T>, BankReadError> {
        let mut items = Vec::new();
        let mut cursor = None;
        loop {
            let mut query = query.to_vec();
            if let Some(cursor) = cursor {
                query.push(("cursor".to_string(), cursor));
            }
            let page: AkahuPage<T> = self.read_page(path, &query).await?;
            items.extend(page.items);
            cursor = page
                .cursor
                .and_then(|cursor| cursor.next)
                .filter(|cursor| !cursor.is_empty());
            if cursor.is_none() {
                return Ok(items);
            }
        }
    }
    pub(crate) async fn list_source_accounts(
        &self,
    ) -> Result<Arc<Vec<AkahuAccount>>, BankReadError> {
        let mut cache = self.accounts.lock().await;
        if let Some((saved, accounts)) = cache.as_ref()
            && saved.elapsed() < Duration::from_secs(300)
        {
            return Ok(accounts.clone());
        }
        *cache = None;
        let accounts = Arc::new(self.list_pages("/accounts", &[]).await?);
        *cache = Some((Instant::now(), accounts.clone()));
        Ok(accounts)
    }
    async fn read_transactions(
        &self,
        from: NaiveDate,
        to: NaiveDate,
    ) -> Result<Vec<BankTransaction>, BankReadError> {
        let accounts = self.list_source_accounts().await?;
        let chunks: Vec<Vec<BankTransaction>> =
            stream::iter(accounts.iter().map(|account| async move {
                let id =
                    percent_encoding::utf8_percent_encode(account.account_id(), AKAHU_ACCOUNT_PATH);
                let path = format!("/accounts/{id}/transactions");
                let query = vec![
                    ("start".to_string(), format!("{from}T00:00:00.000Z")),
                    ("end".to_string(), format!("{to}T23:59:59.999Z")),
                    ("amount_as_number".to_string(), "true".to_string()),
                ];
                let posted: Vec<AkahuTransaction> = self.list_pages(&path, &query).await?;
                let pending: Vec<AkahuPendingTransaction> = self
                    .list_pages(
                        &format!("{path}/pending"),
                        &[query[0].clone(), query[2].clone()],
                    )
                    .await?;
                Ok::<_, BankReadError>(
                    pending
                        .into_iter()
                        .map(|tx| tx.into_bank_transaction(account.currency()))
                        .chain(
                            posted
                                .into_iter()
                                .map(|tx| tx.into_bank_transaction(account.currency())),
                        )
                        .collect(),
                )
            }))
            .buffered(4)
            .try_collect()
            .await?;
        Ok(chunks.into_iter().flatten().collect())
    }
    async fn read_transaction_view(
        &self,
        from: NaiveDate,
        to: NaiveDate,
    ) -> Result<BankTransactionView, BankReadError> {
        let transactions = self.read_transactions(from, to).await?;
        Ok(BankTransactionView {
            snapshot: Arc::new(BankSnapshot {
                from,
                to,
                transactions,
            }),
            range: None,
        })
    }

    /// Reuse shared snapshot records while retaining single-flight source reads.
    pub(crate) async fn fetch_transactions(
        &self,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        snapshot: Option<&str>,
    ) -> Result<BankTransactionView, BankReadError> {
        let from = from.unwrap_or_else(|| (Utc::now() - BankDuration::days(30)).date_naive());
        let to = to.unwrap_or_else(bank_today);
        let Some(snapshot) = snapshot else {
            return self.read_transaction_view(from, to).await;
        };
        let slot = {
            let mut snapshots = self.snapshots.lock().await;
            if let Some(index) = snapshots.iter().position(|(id, _)| id == snapshot) {
                let entry = snapshots.remove(index).expect("Bank snapshot index exists");
                let slot = entry.1.clone();
                snapshots.push_back(entry);
                slot
            } else {
                // Never evict a slot still serving a dashboard, preserving single-flight reads.
                if snapshots.len() >= 4 {
                    if let Some(index) = snapshots
                        .iter()
                        .position(|(_, slot)| Arc::strong_count(slot) == 1)
                    {
                        snapshots.remove(index);
                    } else {
                        drop(snapshots);
                        return self.read_transaction_view(from, to).await;
                    }
                }
                let slot = Arc::new(Mutex::new(None));
                snapshots.push_back((snapshot.to_string(), slot.clone()));
                slot
            }
        };
        let mut cache = slot.lock().await;
        let snapshot = if let Some((saved, snapshot)) = cache.as_ref()
            && saved.elapsed() < Duration::from_secs(60)
        {
            Arc::clone(snapshot)
        } else {
            *cache = None;
            let today = bank_today();
            let start = add_bank_months(today.with_day(1).expect("Bank month has a first day"), -6);
            let transactions = self.read_transactions(start, today).await?;
            let snapshot = Arc::new(BankSnapshot {
                from: start,
                to: today,
                transactions,
            });
            *cache = Some((Instant::now(), Arc::clone(&snapshot)));
            snapshot
        };
        drop(cache);
        if from < snapshot.from || to > snapshot.to {
            return self.read_transaction_view(from, to).await;
        }
        Ok(BankTransactionView {
            snapshot,
            range: Some(from..=to),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bank_models::{AccountId, BankTransactionSource, Money, TransactionId};

    #[test]
    fn transaction_views_share_records_and_preserve_direct_pending_selection() {
        let date = NaiveDate::from_ymd_opt(2024, 3, 2).expect("Valid fixture date");
        let rows = [date - BankDuration::days(1), date].map(|date| BankTransaction {
            source: BankTransactionSource::Pending,
            id: TransactionId(format!("fixture_{date}")),
            account_id: AccountId("fixture_account".into()),
            date,
            description: "Pending fixture".into(),
            merchant: None,
            merchant_logo: None,
            category: None,
            amount: Money::default(),
            currency: "NZD".into(),
        });
        let snapshot = Arc::new(BankSnapshot {
            from: date,
            to: date,
            transactions: rows.into(),
        });
        let filtered = BankTransactionView {
            snapshot: Arc::clone(&snapshot),
            range: Some(date..=date),
        };
        let direct = BankTransactionView {
            snapshot: Arc::clone(&snapshot),
            range: None,
        };
        let record = filtered
            .iter()
            .next()
            .expect("One row is inside the date range");
        assert!(
            std::ptr::eq(record, &snapshot.transactions[1]),
            "Range selection must borrow the cached record"
        );
        assert_eq!(filtered.iter().count(), 1);
        assert_eq!(
            direct.iter().count(),
            2,
            "Direct source reads retain pending records outside the posted range"
        );
        drop(snapshot);
        assert!(std::ptr::eq(
            filtered
                .iter()
                .next()
                .expect("View owns its shared storage"),
            direct
                .iter()
                .nth(1)
                .expect("Direct view shares the same record")
        ));
    }
}
