use crate::ToolResult;
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio::task::{JoinHandle, JoinSet};

/// A loopback-only HTTP request used by synthetic fixtures and in-memory replay.
#[derive(Clone)]
pub struct FixtureRequest {
    pub url: reqwest::Url,
    pub method: String,
    pub headers: BTreeMap<String, String>,
}
/// An HTTP fixture response with an explicit status and no disk storage.
pub struct FixtureResponse {
    pub status: u16,
    pub body: Vec<u8>,
    pub headers: Vec<(String, String)>,
}
impl FixtureResponse {
    pub fn json(value: Value) -> Self {
        Self {
            status: 200,
            body: serde_json::to_vec(&value)
                .expect("A JSON value serializes into an in-memory byte vector"),
            headers: vec![("Content-Type".into(), "application/json".into())],
        }
    }
    pub fn error(status: u16, body: &str) -> Self {
        Self {
            status,
            body: body.as_bytes().to_vec(),
            headers: vec![],
        }
    }
}
type FixtureFuture = Pin<Box<dyn Future<Output = FixtureResponse> + Send>>;
type FixtureHandler = Arc<dyn Fn(FixtureRequest) -> FixtureFuture + Send + Sync>;
/// Own a fixture listener and all connections; dropping it cancels every outstanding handler.
pub struct LoopbackServer {
    pub base_url: String,
    task: JoinHandle<()>,
}
impl LoopbackServer {
    pub async fn start(
        handler: impl Fn(FixtureRequest) -> FixtureFuture + Send + Sync + 'static,
    ) -> ToolResult<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let base_url = format!("http://{}", listener.local_addr()?);
        let handler: FixtureHandler = Arc::new(handler);
        let task = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            loop {
                tokio::select! {
                    connection=listener.accept()=>{let Ok((mut stream,_))=connection else {break;};let handler=handler.clone();connections.spawn(async move {
                        let mut buffer=Vec::new();let mut byte=[0u8;1];
                        while !buffer.ends_with(b"\r\n\r\n") {if buffer.len()>32768 {return;} match stream.read(&mut byte).await {Ok(1)=>buffer.push(byte[0]),_=>return} }
                        let text=String::from_utf8_lossy(&buffer);let mut lines=text.split("\r\n");let mut first=lines.next().unwrap_or("").split_whitespace();
                        let method=first.next().unwrap_or("").to_string();let path=first.next().unwrap_or("/");
                        let Ok(url)=reqwest::Url::parse(&format!("http://localhost{path}")) else {return;};
                        let headers=lines.filter_map(|line|line.split_once(':')).map(|(key,value)|(key.to_ascii_lowercase(),value.trim().to_string())).collect();
                        let request=FixtureRequest {url,method,headers};
                        let response=tokio::select! {response=handler(request)=>response,_=stream.read(&mut byte)=>return};
                        let headers=response.headers.iter().map(|(key,value)|format!("{key}: {value}\r\n")).collect::<String>();
                        let head=format!("HTTP/1.1 {} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n",response.status,response.body.len());
                        let _=stream.write_all(head.as_bytes()).await;let _=stream.write_all(&response.body).await;let _=stream.shutdown().await;
                    });},
                    _=connections.join_next(),if !connections.is_empty()=>{}
                }
            }
        });
        Ok(Self { base_url, task })
    }
}
impl Drop for LoopbackServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Mutable fictional Akahu data and request counters shared by integration checks.
pub struct AkahuFixtureState {
    pub accounts: Vec<Value>,
    pub transactions: Vec<Value>,
    pub pending: Vec<Value>,
    pub calls: Vec<FixtureRequest>,
    pub responses: VecDeque<FixtureResponse>,
    pub page_size: usize,
    pub account_page_size: usize,
    pub latency_ms: u64,
    pub hold_all: bool,
    pub hold_first_history: bool,
    pub credentials_valid: bool,
}
impl Default for AkahuFixtureState {
    fn default() -> Self {
        let accounts=[("acc_main","Everyday","CHECKING",123.45),("acc_save","Savings","SAVINGS",1000.0),("acc_invest","Long term","INVESTMENT",5000.0)].map(|(id,name,kind,balance)|json!({"_id":id,"name":name,"type":kind,"balance":{"current":balance,"currency":"NZD"},"status":"ACTIVE","refreshed":{"balance":"2026-10-20T00:00:00Z","transactions":"2026-10-20T00:00:00Z"}})).to_vec();
        let mut transactions = vec![];
        for (index, date) in ["2026-07-05", "2026-08-05", "2026-09-05", "2026-10-05"]
            .iter()
            .enumerate()
        {
            transactions.push(fixture_transaction(
                &format!("rent_{index}"),
                "acc_main",
                date,
                json!(-75),
                "Rent",
                "Rent",
            ));
        }
        for (id, account, date, amount, merchant, category) in [
            (
                "food",
                "acc_main",
                "2026-10-15",
                -25.5,
                "Grocer",
                "Groceries",
            ),
            (
                "pay",
                "acc_main",
                "2026-10-01",
                1000.0,
                "Employer",
                "Income",
            ),
            (
                "transfer_out",
                "acc_main",
                "2026-10-12",
                -50.0,
                "Transfer",
                "Transfer",
            ),
            (
                "transfer_in",
                "acc_save",
                "2026-10-12",
                50.0,
                "Transfer",
                "Transfer",
            ),
        ] {
            transactions.push(fixture_transaction(
                id,
                account,
                date,
                json!(amount),
                merchant,
                category,
            ));
        }
        Self {
            accounts,
            transactions,
            pending: vec![],
            calls: vec![],
            responses: VecDeque::new(),
            page_size: usize::MAX,
            account_page_size: 2,
            latency_ms: 0,
            hold_all: false,
            hold_first_history: false,
            credentials_valid: true,
        }
    }
}
/// Create a fictional transaction in the source wire format.
pub fn fixture_transaction(
    id: &str,
    account: &str,
    date: &str,
    amount: Value,
    merchant: &str,
    category: &str,
) -> Value {
    json!({"_id":id,"_account":account,"date":format!("{date}T00:00:00Z"),"amount":amount,"description":merchant,"merchant":{"name":merchant},"meta":{"logo":"https://cdn.akahu.nz/fixture.png"},"category":{"_id":category,"name":category}})
}
/// Host mutable fictional accounts, cursor pages, injected failures, and cancellable hanging reads.
pub struct AkahuFixture {
    pub server: LoopbackServer,
    pub state: Arc<Mutex<AkahuFixtureState>>,
    pub started: Arc<Notify>,
    pub disconnected: Arc<Notify>,
}
struct DisconnectGuard(Arc<Notify>);
impl Drop for DisconnectGuard {
    fn drop(&mut self) {
        self.0.notify_one();
    }
}
impl AkahuFixture {
    pub async fn start(
        state: AkahuFixtureState,
        app_token: &str,
        user_token: &str,
    ) -> ToolResult<Self> {
        let state = Arc::new(Mutex::new(state));
        let started = Arc::new(Notify::new());
        let disconnected = Arc::new(Notify::new());
        let (data, begin, end) = (state.clone(), started.clone(), disconnected.clone());
        let (app, user) = (app_token.to_string(), user_token.to_string());
        let server = LoopbackServer::start(move |request| {
            let (state, started, disconnected, app, user) = (
                data.clone(),
                begin.clone(),
                end.clone(),
                app.clone(),
                user.clone(),
            );
            Box::pin(async move {
                let (hold, latency, response) = {
                    let mut state = state
                        .lock()
                        .expect("Akahu fixture state mutex is not poisoned");
                    state.credentials_valid &= request.headers.get("authorization")
                        == Some(&format!("Bearer {user}"))
                        && request.headers.get("x-akahu-id") == Some(&app);
                    let path = request.url.path().to_string();
                    state.calls.push(request.clone());
                    let hold = state.hold_all
                        || state.hold_first_history && path.ends_with("/transactions");
                    if hold {
                        state.hold_first_history = false;
                    }
                    let response = if let Some(injected) = state.responses.pop_front() {
                        injected
                    } else {
                        fixture_page(&state, &request)
                    };
                    (hold, state.latency_ms, response)
                };
                if hold {
                    let _guard = DisconnectGuard(disconnected);
                    started.notify_one();
                    std::future::pending::<()>().await;
                }
                if latency > 0 {
                    tokio::time::sleep(Duration::from_millis(latency)).await;
                }
                response
            })
        })
        .await?;
        Ok(Self {
            server,
            state,
            started,
            disconnected,
        })
    }
    pub fn base_url(&self) -> String {
        format!("{}/v1", self.server.base_url)
    }
}
fn fixture_page(state: &AkahuFixtureState, request: &FixtureRequest) -> FixtureResponse {
    let path = request.url.path();
    let query: BTreeMap<_, _> = request.url.query_pairs().into_owned().collect();
    let mut cursor = None;
    let items = if path == "/v1/accounts" {
        if query.contains_key("cursor") {
            state
                .accounts
                .iter()
                .skip(state.account_page_size)
                .cloned()
                .collect::<Vec<_>>()
        } else {
            if state.accounts.len() > state.account_page_size {
                cursor = Some("second-page".to_string());
            }
            state
                .accounts
                .iter()
                .take(state.account_page_size)
                .cloned()
                .collect()
        }
    } else if path.ends_with("/transactions/pending") {
        let account = path.split('/').nth(3).unwrap_or("");
        state
            .pending
            .iter()
            .filter(|row| {
                row["_account"]
                    .as_str()
                    .or(row["account"].as_str())
                    .unwrap_or("acc_main")
                    == account
            })
            .cloned()
            .collect()
    } else if path.ends_with("/transactions") {
        let account = path.split('/').nth(3).unwrap_or("");
        let start = query.get("start").map(String::as_str).unwrap_or("");
        let end = query.get("end").map(String::as_str).unwrap_or("9999");
        let matching: Vec<_> = state
            .transactions
            .iter()
            .filter(|row| {
                row["_account"] == account
                    && row["date"]
                        .as_str()
                        .is_some_and(|date| date >= start && date <= end)
            })
            .cloned()
            .collect();
        let offset = query
            .get("cursor")
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        if offset.saturating_add(state.page_size) < matching.len() {
            cursor = Some((offset + state.page_size).to_string());
        }
        matching
            .into_iter()
            .skip(offset)
            .take(state.page_size)
            .collect()
    } else {
        return FixtureResponse::error(404, "");
    };
    FixtureResponse::json(json!({"success":true,"items":items,"cursor":{"next":cursor}}))
}
