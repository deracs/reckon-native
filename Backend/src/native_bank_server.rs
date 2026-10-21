use crate::{
    akahu_bank_data::AkahuBankData,
    backend_handshake::BackendSecret,
    bank_calendar::{add_bank_months, bank_today, parse_bank_date},
    bank_derivations::{
        detect_bank_recurring, filter_bank_transfers, forecast_bank_cashflow,
        summarize_bank_cashflow, summarize_bank_spending,
    },
    bank_models::AccountId,
};
use bigdecimal::{BigDecimal, Signed};
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, Response, StatusCode, body::Incoming};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    convert::Infallible,
};
use subtle::ConstantTimeEq;

struct BankQuery(HashMap<String, String>);
impl BankQuery {
    fn parse_query(query: Option<&str>) -> Result<Self, ()> {
        let mut values = HashMap::new();
        for (key, value) in
            reqwest::Url::parse(&format!("http://localhost/?{}", query.unwrap_or("")))
                .map_err(|_| ())?
                .query_pairs()
        {
            if values
                .insert(key.into_owned(), value.into_owned())
                .is_some()
            {
                return Err(());
            }
        }
        Ok(Self(values))
    }
    fn date(&self, key: &str) -> Result<Option<chrono::NaiveDate>, ()> {
        self.0
            .get(key)
            .map(|s| parse_bank_date(s).ok_or(()))
            .transpose()
    }
    fn number(&self, key: &str, default: f64) -> Result<f64, ()> {
        self.0.get(key).map_or(Ok(default), |s| {
            s.trim()
                .parse::<f64>()
                .map_err(|_| ())
                .and_then(|n| if n.is_finite() { Ok(n) } else { Err(()) })
        })
    }
    fn boolean(&self, key: &str, default: bool) -> Result<bool, ()> {
        match self.0.get(key).map(String::as_str) {
            None => Ok(default),
            Some("true") => Ok(true),
            Some("false") => Ok(false),
            _ => Err(()),
        }
    }
}
fn bank_response(status: StatusCode, text: &str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .body(Full::new(Bytes::copy_from_slice(text.as_bytes())))
        .expect("Bank response status is valid")
}

/// The loopback HTTP boundary permits authenticated GET bank reads and rejects browser origins.
pub(crate) async fn serve_bank_request(
    request: Request<Incoming>,
    port: u16,
    token: &BackendSecret,
    bank: &AkahuBankData,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok());
    if header("host") != Some(format!("127.0.0.1:{port}").as_str())
        || request.headers().contains_key("origin")
    {
        return Ok(bank_response(StatusCode::FORBIDDEN, ""));
    }
    let expected = format!("Bearer {}", token.expose());
    if !bool::from(
        header("authorization")
            .unwrap_or("")
            .as_bytes()
            .ct_eq(expected.as_bytes()),
    ) {
        return Ok(bank_response(StatusCode::UNAUTHORIZED, ""));
    }
    let path = request.uri().path();
    if request.method() != hyper::Method::GET
        || !matches!(
            path,
            "/health"
                | "/accounts"
                | "/freshness"
                | "/cashflow"
                | "/spending"
                | "/transactions"
                | "/recurring"
                | "/forecast"
        )
    {
        return Ok(bank_response(StatusCode::NOT_FOUND, ""));
    }
    if path == "/health" {
        return Ok(json_bank_response(json!({"status":"ok"})));
    }
    let snapshot = header("x-reckon-snapshot");
    if snapshot.is_some_and(|s| s.len() != 36 || uuid::Uuid::parse_str(s).is_err()) {
        return Ok(bank_response(
            StatusCode::BAD_REQUEST,
            "Invalid bank snapshot.",
        ));
    }
    let parsed = (|| {
        let query = BankQuery::parse_query(request.uri().query())?;
        let range_route = matches!(
            path,
            "/cashflow" | "/spending" | "/transactions" | "/recurring"
        );
        let from = if range_route {
            query.date("from")?
        } else {
            None
        };
        let to = if range_route { query.date("to")? } else { None };
        let exclude = if matches!(
            path,
            "/cashflow" | "/spending" | "/transactions" | "/forecast"
        ) {
            query.boolean("excludeTransfers", path != "/transactions")?
        } else {
            true
        };
        let limit = if path == "/transactions" {
            query.number("limit", 25.)?
        } else {
            25.
        };
        let minimum = if path == "/recurring" {
            query.number("minOccurrences", 3.)?
        } else {
            3.
        };
        let days = if path == "/forecast" {
            query.number("days", 30.)?
        } else {
            30.
        };
        Ok::<_, ()>((query, from, to, exclude, limit, minimum, days))
    })();
    let Ok((query, from, to, exclude, limit, minimum, days)) = parsed else {
        return Ok(bank_response(
            StatusCode::BAD_REQUEST,
            "Invalid bank query.",
        ));
    };
    let result: Result<Value, crate::akahu_bank_data::BankReadError> = async {
        if matches!(path, "/accounts" | "/freshness") {
            let accounts = bank.list_source_accounts().await?;
            return Ok(if path == "/accounts" {
                json!(
                    accounts
                        .iter()
                        .map(|a| a.to_bank_account())
                        .collect::<Vec<_>>()
                )
            } else {
                json!(
                    accounts
                        .iter()
                        .map(|a| a.to_account_freshness())
                        .collect::<Vec<_>>()
                )
            });
        }
        if path == "/forecast" {
            let today = bank_today();
            let accounts: Vec<_> = bank
                .list_source_accounts()
                .await?
                .iter()
                .map(|a| a.to_bank_account())
                .filter(|a| a.is_liquid_nzd())
                .collect();
            let ids: HashSet<AccountId> = accounts.iter().map(|a| a.id.clone()).collect();
            let history = bank
                .fetch_transactions(Some(add_bank_months(today, -6)), Some(today), snapshot)
                .await?;
            let cleaned: Vec<_> = filter_bank_transfers(&history, exclude)
                .into_iter()
                .filter(|tx| ids.contains(&tx.account_id))
                .collect();
            let incoming: Vec<_> = cleaned
                .iter()
                .filter(|tx| tx.amount.0.is_positive())
                .map(|tx| {
                    let mut tx = tx.clone();
                    tx.amount.0 = -tx.amount.0;
                    tx
                })
                .collect();
            return Ok(forecast_bank_cashflow(
                accounts
                    .into_iter()
                    .map(|a| a.balance.0)
                    .sum::<BigDecimal>(),
                today,
                days,
                &detect_bank_recurring(&cleaned, 3.),
                &detect_bank_recurring(&incoming, 2.),
            ));
        }
        let history = bank.fetch_transactions(from, to, snapshot).await?;
        let mut cleaned = filter_bank_transfers(&history, exclude);
        Ok(match path {
            "/spending" => summarize_bank_spending(&cleaned),
            "/cashflow" => summarize_bank_cashflow(&cleaned),
            "/recurring" => json!(detect_bank_recurring(&cleaned, minimum)),
            "/transactions" => {
                let search = query
                    .0
                    .get("query")
                    .map(|s| s.to_lowercase())
                    .unwrap_or_default();
                cleaned.retain(|tx| {
                    [
                        (query.0.get("accountId"), Some(&tx.account_id.0)),
                        (query.0.get("category"), tx.category.as_ref()),
                    ]
                    .iter()
                    .all(|(filter, value)| {
                        filter.is_none_or(|filter| filter.is_empty() || Some(filter) == *value)
                    }) && (search.is_empty()
                        || [
                            Some(&tx.description),
                            tx.merchant.as_ref(),
                            tx.category.as_ref(),
                        ]
                        .into_iter()
                        .flatten()
                        .any(|s| s.to_lowercase().contains(&search)))
                        && from.is_none_or(|d| tx.date >= d)
                        && to.is_none_or(|d| tx.date <= d)
                });
                cleaned.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| b.id.0.cmp(&a.id.0)));
                cleaned.truncate(limit.clamp(1., 100.).floor() as usize);
                json!(cleaned)
            }
            _ => unreachable!("Bank route was checked before reading history"),
        })
    }
    .await;
    Ok(match result {
        Ok(value) => json_bank_response(value),
        Err(_) => bank_response(StatusCode::BAD_GATEWAY, "Could not read Akahu data."),
    })
}
fn json_bank_response(value: Value) -> Response<Full<Bytes>> {
    let mut response = bank_response(StatusCode::OK, &value.to_string());
    response.headers_mut().insert(
        hyper::header::CONTENT_TYPE,
        hyper::header::HeaderValue::from_static("application/json"),
    );
    response
}
