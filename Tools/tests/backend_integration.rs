use chrono::{NaiveDate, Utc};
use reckon_tools::backend_process::{BackendProcess, BackendTarget};
use reckon_tools::loopback_fixture::{
    AkahuFixture, AkahuFixtureState, FixtureResponse, LoopbackServer,
};
use reckon_tools::{ToolResult, project_root};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
const APP: &str = "app_token_local_fixture";
const USER: &str = "user_token_local_fixture";
const API: &str = "local-api-fixture-local-api-fixture-local-api-fixture-local-api-fixture-";
fn target() -> BackendTarget {
    BackendTarget::rust(
        &std::env::var_os("RECKON_APP_BUNDLE")
            .map(PathBuf::from)
            .unwrap_or_else(|| project_root().join("dist/Reckon.app")),
    )
}
fn handshake(base: Option<&str>) -> Value {
    let mut value = json!({"appToken":APP,"userToken":USER,"apiToken":API});
    if let Some(base) = base {
        value["akahuBaseURL"] = json!(base);
    }
    value
}
struct Check {
    fixture: AkahuFixture,
    backend: BackendProcess,
    client: reqwest::Client,
    base: String,
}
impl Check {
    async fn start(state: AkahuFixtureState) -> Self {
        let fixture = AkahuFixture::start(state, APP, USER).await.unwrap();
        let backend = BackendProcess::launch(&target(), &handshake(Some(&fixture.base_url())))
            .await
            .unwrap();
        let base = backend.base_url().unwrap();
        Self {
            fixture,
            backend,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap(),
            base,
        }
    }
    fn get(&self, path: &str) -> reqwest::RequestBuilder {
        self.client
            .get(format!("{}{path}", self.base))
            .bearer_auth(API)
    }
    async fn json(&self, path: &str) -> Value {
        let response = self.get(path).send().await.unwrap();
        assert_eq!(response.status(), 200, "{path}");
        response.json().await.unwrap()
    }
    async fn finish(mut self) {
        assert!(self.backend.stop().await.unwrap().success());
        self.backend
            .assert_no_secret_output(&[APP, USER, API])
            .await
            .unwrap();
        assert!(
            self.fixture.state.lock().unwrap().credentials_valid,
            "Akahu credentials did not match fixture"
        );
    }
}
fn date_shift(value: &str) -> String {
    let today = Utc::now()
        .with_timezone(&chrono_tz::Pacific::Auckland)
        .date_naive();
    let offset = today - NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
    (NaiveDate::parse_from_str(value, "%Y-%m-%d").unwrap() + offset).to_string()
}
fn dated_state() -> AkahuFixtureState {
    let mut state = AkahuFixtureState::default();
    for row in &mut state.transactions {
        let date = row["date"].as_str().unwrap();
        row["date"] = json!(format!("{}T00:00:00Z", date_shift(&date[..10])));
    }
    state
}
fn current_range() -> String {
    format!(
        "from={}&to={}&excludeTransfers=true",
        date_shift("2026-10-01"),
        date_shift("2026-10-20")
    )
}
fn category_spent(data: &Value, category: &str) -> Value {
    data.as_array()
        .unwrap()
        .iter()
        .find(|row| row["category"] == category)
        .unwrap()["spent"]
        .clone()
}

#[tokio::test]
async fn standalone_bundle_serves_calculations_and_enforces_the_http_boundary() {
    let check = Check::start(AkahuFixtureState::default()).await;
    assert_eq!(check.json("/health").await, json!({"status":"ok"}));
    let accounts = check.json("/accounts").await;
    assert_eq!(accounts.as_array().unwrap().len(), 3);
    assert_eq!(accounts[0]["balance"], "123.45");
    assert_eq!(accounts[1]["type"], "savings");
    let range = "from=2026-10-01&to=2026-10-20&excludeTransfers=true";
    let cash = check.json(&format!("/cashflow?{range}")).await;
    assert_eq!(cash[0]["income"], "1000");
    assert_eq!(cash[0]["spending"], "100.5");
    assert_eq!(cash[0]["net"], "899.5");
    let spending = check.json(&format!("/spending?{range}")).await;
    let categories: HashSet<_> = spending
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["category"].as_str().unwrap())
        .collect();
    assert_eq!(categories, HashSet::from(["Groceries", "Rent"]));
    assert_eq!(
        check
            .json("/spending?from=2026-07-01&to=2026-09-30&excludeTransfers=true")
            .await[0]["spent"],
        "225"
    );
    let recurring = check.json("/recurring?from=2026-04-20&to=2026-10-20").await;
    assert_eq!(
        recurring
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["merchant"] == "Rent")
            .unwrap()["cadence"],
        "monthly"
    );
    assert_eq!(
        check.json("/freshness").await[0]["transactionsRefreshedAt"],
        "2026-10-20T00:00:00.000Z"
    );
    assert_eq!(
        check
            .client
            .get(format!("{}/accounts", check.base))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        check
            .client
            .get(format!("{}/health", check.base))
            .bearer_auth("incorrect")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        check
            .get("/accounts")
            .header("Origin", "https://example.invalid")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        check
            .get("/health")
            .header("Host", "attacker.invalid")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    for path in ["/refresh", "/transactions"] {
        assert_eq!(
            check
                .client
                .post(format!("{}{path}", check.base))
                .bearer_auth(API)
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
    }
    assert_eq!(check.get("/docs").send().await.unwrap().status(), 404);
    assert_eq!(
        check
            .client
            .get(format!("{}/forecast", check.base))
            .bearer_auth("wrong")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let transactions = check
        .json(&format!("/transactions?{range}&limit=100"))
        .await;
    let rows = transactions.as_array().unwrap();
    assert!(!rows.is_empty());
    assert!(
        rows.iter()
            .all(|row| !row["id"].as_str().unwrap().starts_with("transfer_"))
    );
    assert_eq!(
        rows.iter().find(|row| row["id"] == "food").unwrap()["merchantLogo"],
        "https://cdn.akahu.nz/fixture.png"
    );
    let forecast = check.json("/forecast?days=30&excludeTransfers=true").await;
    assert_eq!(forecast["startingBalance"], "1123.45");
    assert_eq!(forecast["points"].as_array().unwrap().len(), 31);
    assert!(
        check
            .fixture
            .state
            .lock()
            .unwrap()
            .calls
            .iter()
            .all(|call| call.method == "GET")
    );
    check.finish().await;
}
#[tokio::test]
async fn app_pipe_closure_stops_backend_and_releases_listener() {
    let mut backend = BackendProcess::launch(&target(), &handshake(None))
        .await
        .unwrap();
    let url = backend.base_url().unwrap();
    assert!(backend.stop().await.unwrap().success());
    assert!(reqwest::get(format!("{url}/health")).await.is_err());
    backend
        .assert_no_secret_output(&[APP, USER, API])
        .await
        .unwrap();
}
async fn signal_stops(signal: &str) {
    let mut backend = BackendProcess::launch(&target(), &handshake(None))
        .await
        .unwrap();
    let url = backend.base_url().unwrap();
    assert!(
        std::process::Command::new("/bin/kill")
            .args([signal, &backend.child.id().unwrap().to_string()])
            .status()
            .unwrap()
            .success()
    );
    assert!(
        tokio::time::timeout(Duration::from_secs(4), backend.child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
    assert!(reqwest::get(format!("{url}/health")).await.is_err());
    backend
        .assert_no_secret_output(&[APP, USER, API])
        .await
        .unwrap();
}
#[tokio::test]
async fn sigint_stops_backend_cleanly() {
    signal_stops("-INT").await;
}
#[tokio::test]
async fn sigterm_stops_backend_cleanly() {
    signal_stops("-TERM").await;
}
#[tokio::test]
async fn malformed_queries_and_snapshots_fail_before_upstream_requests() {
    let check = Check::start(AkahuFixtureState::default()).await;
    for value in ["NaN", "Infinity", "-Infinity", "1e309"] {
        for path in [
            "/transactions?limit=",
            "/recurring?minOccurrences=",
            "/forecast?days=",
        ] {
            assert_eq!(
                check
                    .get(&format!("{path}{value}"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                400
            );
        }
    }
    for path in [
        "/transactions?limit=1&limit=2",
        "/forecast?excludeTransfers=yes",
        "/spending?excludeTransfers=1",
        "/spending?from=2026-02-30",
        "/cashflow?to=not-a-date",
        "/recurring?from=2026-01-01&from=2026-02-01",
    ] {
        assert_eq!(check.get(path).send().await.unwrap().status(), 400);
    }
    for snapshot in ["".to_string(), "not-a-uuid".into(), "a".repeat(4096)] {
        assert_eq!(
            check
                .get("/accounts")
                .header("X-Reckon-Snapshot", snapshot)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    for path in [
        "/budgets",
        "/goals",
        "/categories",
        "/unusual",
        "/constructor",
        "/__proto__",
    ] {
        assert_eq!(check.get(path).send().await.unwrap().status(), 404);
    }
    assert!(check.fixture.state.lock().unwrap().calls.is_empty());
    check.finish().await;
}
#[tokio::test]
async fn transient_failures_retry_and_preserve_cursor_pagination() {
    let mut state = AkahuFixtureState::default();
    state
        .responses
        .push_back(FixtureResponse::error(503, "temporarily unavailable"));
    let check = Check::start(state).await;
    assert_eq!(check.json("/accounts").await.as_array().unwrap().len(), 3);
    {
        let state = check.fixture.state.lock().unwrap();
        assert_eq!(state.calls.len(), 3);
        assert_eq!(state.calls[0].url, state.calls[1].url);
        assert_eq!(
            state.calls[2]
                .url
                .query_pairs()
                .find(|(key, _)| key == "cursor")
                .unwrap()
                .1,
            "second-page"
        );
    }
    check.finish().await;
}
#[tokio::test]
async fn transient_failures_stop_after_five_retries() {
    let mut state = AkahuFixtureState::default();
    for _ in 0..6 {
        state
            .responses
            .push_back(FixtureResponse::error(503, "temporarily unavailable"));
    }
    let check = Check::start(state).await;
    let response = check.get("/accounts").send().await.unwrap();
    assert_eq!(response.status(), 502);
    assert_eq!(response.text().await.unwrap(), "Could not read Akahu data.");
    assert_eq!(check.fixture.state.lock().unwrap().calls.len(), 6);
    check.finish().await;
}
#[tokio::test]
async fn permanent_failures_and_invalid_json_do_not_retry_or_disclose_source_details() {
    for response in [
        FixtureResponse::error(401, "private upstream detail"),
        FixtureResponse::error(200, "{"),
    ] {
        let mut state = AkahuFixtureState::default();
        state.responses.push_back(response);
        let check = Check::start(state).await;
        let response = check.get("/accounts").send().await.unwrap();
        assert_eq!(response.status(), 502);
        assert_eq!(response.text().await.unwrap(), "Could not read Akahu data.");
        assert_eq!(check.fixture.state.lock().unwrap().calls.len(), 1);
        check.finish().await;
    }
}
#[tokio::test]
async fn redirects_never_forward_credentials() {
    let forwarded = Arc::new(AtomicUsize::new(0));
    let requests = forwarded.clone();
    let destination = LoopbackServer::start(move |_| {
        requests.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { FixtureResponse::json(json!({})) })
    })
    .await
    .unwrap();
    let mut response = FixtureResponse::error(302, "");
    response.headers.push((
        "location".into(),
        format!("{}/capture", destination.base_url),
    ));
    let mut state = AkahuFixtureState::default();
    state.responses.push_back(response);
    let check = Check::start(state).await;
    let response = check.get("/accounts").send().await.unwrap();
    assert_eq!(response.status(), 502);
    assert_eq!(response.text().await.unwrap(), "Could not read Akahu data.");
    assert_eq!(forwarded.load(Ordering::SeqCst), 0);
    assert_eq!(check.fixture.state.lock().unwrap().calls.len(), 1);
    check.finish().await;
}
async fn cancellation_stops_upstream(shutdown: bool) {
    let state = AkahuFixtureState {
        hold_all: true,
        ..Default::default()
    };
    let mut check = Check::start(state).await;
    let request = check.get("/accounts");
    let pending = tokio::spawn(async move { request.send().await });
    tokio::time::timeout(Duration::from_secs(6), check.fixture.started.notified())
        .await
        .unwrap();
    if shutdown {
        assert!(check.backend.stop().await.unwrap().success());
    } else {
        pending.abort();
    }
    tokio::time::timeout(
        Duration::from_secs(6),
        check.fixture.disconnected.notified(),
    )
    .await
    .unwrap();
    assert!(
        pending
            .await
            .map(|response| response.is_err())
            .unwrap_or(true)
    );
    check.finish().await;
}
#[tokio::test]
async fn client_disconnect_cancels_inflight_source_request() {
    cancellation_stops_upstream(false).await;
}
#[tokio::test]
async fn app_shutdown_cancels_inflight_source_request() {
    cancellation_stops_upstream(true).await;
}
#[tokio::test]
async fn nonfinite_source_money_fails_without_source_data_in_errors() {
    for field in ["current", "available", "limit", "amount"] {
        for value in ["NaN", "Infinity", "-Infinity", "1e309"] {
            let mut state = AkahuFixtureState::default();
            let path = if field == "amount" {
                state
                    .transactions
                    .iter_mut()
                    .find(|row| row["_id"] == "food")
                    .unwrap()["amount"] = json!(value);
                "/transactions?from=2026-10-01&to=2026-10-20"
            } else {
                state.accounts[0]["balance"][field] = json!(value);
                "/accounts"
            };
            let check = Check::start(state).await;
            let response = check.get(path).send().await.unwrap();
            assert_eq!(response.status(), 502);
            let body = response.text().await.unwrap();
            for secret in [value, "acc_main", "Grocer", APP, USER, API] {
                assert!(!body.contains(secret));
            }
            check.finish().await;
        }
    }
}
#[tokio::test]
async fn finite_money_strings_preserve_projection_and_transaction_metadata() {
    let mut state = AkahuFixtureState::default();
    state.accounts[0]["balance"] =
        json!({"current":"-12.50","available":"0","limit":"250.75","currency":"NZD"});
    state
        .transactions
        .iter_mut()
        .find(|row| row["_id"] == "food")
        .unwrap()["amount"] = json!("-25.50");
    let check = Check::start(state).await;
    let accounts = check.json("/accounts").await;
    assert_eq!(accounts[0]["balance"], "-12.5");
    assert_eq!(accounts[0]["availableBalance"], "0");
    assert_eq!(accounts[0]["creditLimit"], "250.75");
    let transactions = check
        .json("/transactions?from=2026-10-01&to=2026-10-20")
        .await;
    let food = transactions
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == "food")
        .unwrap();
    assert_eq!(food["amount"], "-25.5");
    assert_eq!(food["merchant"], "Grocer");
    assert_eq!(food["category"], "Groceries");
    check.finish().await;
}
#[tokio::test]
async fn invalid_startup_credentials_fail_without_listener_or_secret_output() {
    let mut input = handshake(None);
    input["apiToken"] = json!("bad token");
    let mut backend = BackendProcess::launch(&target(), &input).await.unwrap();
    assert_eq!(backend.ready, json!({"event":"failed"}));
    assert!(!backend.stop().await.unwrap().success());
    backend
        .assert_no_secret_output(&[APP, USER, API, "bad token"])
        .await
        .unwrap();
}
#[tokio::test]
async fn snapshot_shares_each_page_once_and_new_snapshot_reads_fresh_data() {
    let mut state = dated_state();
    state.page_size = 2;
    let check = Check::start(state).await;
    let snapshot = uuid::Uuid::new_v4().to_string();
    let range = current_range();
    let history = format!(
        "from={}&to={}",
        date_shift("2026-07-01"),
        date_shift("2026-10-20")
    );
    let paths = [
        "/accounts".into(),
        format!("/cashflow?{range}"),
        format!("/spending?{range}"),
        format!(
            "/spending?from={}&to={}&excludeTransfers=true",
            date_shift("2026-07-01"),
            date_shift("2026-09-30")
        ),
        format!("/recurring?{history}"),
        "/freshness".into(),
        format!("/transactions?{history}&limit=100&excludeTransfers=true"),
        "/forecast?days=30&excludeTransfers=true".into(),
    ];
    let responses = futures_util::future::join_all(paths.iter().map(|path| {
        let check = &check;
        let snapshot = &snapshot;
        async move {
            let response = check
                .get(path)
                .header("X-Reckon-Snapshot", snapshot)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200, "{path}");
            response.json::<Value>().await.unwrap()
        }
    }))
    .await;
    assert_eq!(responses[0].as_array().unwrap().len(), 3);
    assert_eq!(category_spent(&responses[2], "Groceries"), "25.5");
    assert_eq!(category_spent(&responses[3], "Rent"), "225");
    assert!(
        responses[6]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| !row["id"].as_str().unwrap().starts_with("transfer_"))
    );
    assert_eq!(responses[7]["startingBalance"], "1123.45");
    let history_count;
    {
        let mut state = check.fixture.state.lock().unwrap();
        assert_eq!(
            state
                .calls
                .iter()
                .filter(|call| call.url.path() == "/v1/accounts")
                .count(),
            2
        );
        let calls: Vec<_> = state
            .calls
            .iter()
            .filter(|call| call.url.path().contains("/transactions"))
            .collect();
        history_count = calls.len();
        assert_eq!(
            calls
                .iter()
                .map(|call| call.url.as_str())
                .collect::<HashSet<_>>()
                .len(),
            calls.len()
        );
        assert_eq!(
            calls
                .iter()
                .filter(|call| call.url.path().ends_with("/pending"))
                .count(),
            3
        );
        assert_eq!(history_count, 9);
        state
            .transactions
            .iter_mut()
            .find(|row| row["_id"] == "food")
            .unwrap()["amount"] = json!(-30);
    }
    let path = format!("/spending?{range}");
    let cached: Value = check
        .get(&path)
        .header("X-Reckon-Snapshot", &snapshot)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(category_spent(&cached, "Groceries"), "25.5");
    let fresh: Value = check
        .get(&path)
        .header("X-Reckon-Snapshot", uuid::Uuid::new_v4().to_string())
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(category_spent(&fresh, "Groceries"), "30");
    assert_eq!(
        check
            .fixture
            .state
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|call| call.url.path().contains("/transactions"))
            .count(),
        history_count * 2
    );
    check.finish().await;
}
#[tokio::test]
async fn failed_accounts_and_snapshot_history_recover_immediately() {
    let mut state = dated_state();
    state
        .responses
        .push_back(FixtureResponse::error(401, "private source failure"));
    let check = Check::start(state).await;
    let snapshot = uuid::Uuid::new_v4().to_string();
    assert_eq!(
        check
            .get("/accounts")
            .header("X-Reckon-Snapshot", &snapshot)
            .send()
            .await
            .unwrap()
            .status(),
        502
    );
    assert_eq!(
        check
            .get("/accounts")
            .header("X-Reckon-Snapshot", &snapshot)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    check
        .fixture
        .state
        .lock()
        .unwrap()
        .responses
        .push_back(FixtureResponse::error(401, "private history failure"));
    let path = format!("/spending?{}", current_range());
    assert_eq!(
        check
            .get(&path)
            .header("X-Reckon-Snapshot", &snapshot)
            .send()
            .await
            .unwrap()
            .status(),
        502
    );
    let response = check
        .get(&path)
        .header("X-Reckon-Snapshot", &snapshot)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        category_spent(&response.json().await.unwrap(), "Groceries"),
        "25.5"
    );
    check.finish().await;
}
#[tokio::test]
async fn abandoned_snapshot_cancels_shared_history_and_same_id_recovers() {
    let mut state = dated_state();
    state.hold_first_history = true;
    let check = Check::start(state).await;
    let snapshot = uuid::Uuid::new_v4().to_string();
    let path = format!("/spending?{}", current_range());
    let request = check.get(&path).header("X-Reckon-Snapshot", &snapshot);
    let pending = tokio::spawn(async move { request.send().await });
    tokio::time::timeout(Duration::from_secs(6), check.fixture.started.notified())
        .await
        .unwrap();
    pending.abort();
    assert!(pending.await.is_err());
    tokio::time::timeout(
        Duration::from_secs(6),
        check.fixture.disconnected.notified(),
    )
    .await
    .unwrap();
    let response = check
        .get(&path)
        .header("X-Reckon-Snapshot", &snapshot)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        category_spent(&response.json().await.unwrap(), "Groceries"),
        "25.5"
    );
    check.finish().await;
}
#[tokio::test]
#[ignore = "Requires RECKON_BASELINE_BUNDLE with its historical runtime"]
async fn optional_historical_typescript_bundle_returns_identical_json() -> ToolResult {
    let bundle = std::env::var_os("RECKON_BASELINE_BUNDLE")
        .ok_or("Historical comparison requires a saved baseline bundle.")?;
    let mut state = dated_state();
    state.page_size = 2;
    let today = date_shift("2026-10-20");
    state.transactions.push(json!({"_id":"metadata_free","_account":"acc_main","date":format!("{today}T00:00:00Z"),"description":"No metadata fixture","amount":-1.005}));
    state.pending = vec![
        json!({"account":"acc_main","date":format!("{today}T00:00:00Z"),"description":"Pending fixture","amount":"-12.50"}),
        json!({"_account":"acc_save","date":format!("{today}T00:00:00Z"),"description":"Small pending fixture","amount":-1e-7}),
        json!({"date":format!("{today}T00:00:00Z"),"description":"Unknown pending fixture","amount":0}),
    ];
    let check = Check::start(state).await;
    let mut baseline = BackendProcess::launch(
        &BackendTarget::historical_typescript(&PathBuf::from(bundle)),
        &handshake(Some(&check.fixture.base_url())),
    )
    .await?;
    let base = baseline.base_url()?;
    let history = format!("from={}&to={today}", date_shift("2026-07-01"));
    let paths = [
        "/accounts".into(),
        "/freshness".into(),
        format!("/transactions?{history}&limit=100"),
        format!("/transactions?{history}&excludeTransfers=true&query=rent&limit=2"),
        format!("/cashflow?{history}"),
        format!("/spending?{history}&excludeTransfers=false"),
        format!("/recurring?{history}&minOccurrences=2"),
        "/forecast?days=30&excludeTransfers=true".into(),
    ];
    for path in paths {
        let rust: Value = check
            .get(&path)
            .header("X-Reckon-Snapshot", "00000000-0000-4000-8000-000000000001")
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let original: Value = check
            .client
            .get(format!("{base}{path}"))
            .bearer_auth(API)
            .header("X-Reckon-Snapshot", "00000000-0000-4000-8000-000000000001")
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        assert_eq!(rust, original, "{path}");
    }
    assert!(baseline.stop().await?.success());
    baseline.assert_no_secret_output(&[APP, USER, API]).await?;
    check.finish().await;
    Ok(())
}
