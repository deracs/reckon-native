use crate::backend_benchmark::{
    backend_binary_metadata, benchmark_environment, benchmark_today, bounded_runs, dashboard_paths,
    summarize_samples,
};
use crate::backend_process::{BackendProcess, BackendTarget, load_bank_dashboard};
use crate::loopback_fixture::{FixtureResponse, LoopbackServer};
use crate::{ToolResult, command_output, project_root, tool_options};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use zeroize::Zeroizing;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SavedConnection {
    app_token: String,
    user_token: String,
}
struct BankConnection {
    app: Zeroizing<String>,
    user: Zeroizing<String>,
}
impl BankConnection {
    fn read_keychain() -> ToolResult<Self> {
        let bytes = Zeroizing::new(command_output(
            Command::new("/usr/bin/security").args([
                "find-generic-password",
                "-s",
                "nz.reckon.native.connection",
                "-a",
                "akahu-personal-app",
                "-w",
            ]),
            None,
        )?);
        let connection: SavedConnection =
            serde_json::from_slice(&bytes).map_err(|_| "Saved connection is invalid.")?;
        let result = Self {
            app: Zeroizing::new(connection.app_token),
            user: Zeroizing::new(connection.user_token),
        };
        if [&result.app, &result.user].iter().any(|s| {
            s.is_empty() || s.len() > 4096 || !s.bytes().all(|b| (0x21..=0x7e).contains(&b))
        }) {
            return Err("Saved connection is invalid.".into());
        }
        Ok(result)
    }
    fn handshake(&self, api: &str, base: Option<&str>) -> Value {
        let mut input =
            json!({"appToken":self.app.as_str(),"userToken":self.user.as_str(),"apiToken":api});
        if let Some(base) = base {
            input["akahuBaseURL"] = json!(base);
        }
        input
    }
}
#[derive(Serialize)]
struct LiveSample {
    #[serde(rename = "startupMs")]
    startup: f64,
    #[serde(rename = "dashboardMs")]
    dashboard: f64,
    #[serde(rename = "startupAndDashboardMs")]
    total: f64,
    #[serde(rename = "startupRssMiB")]
    startup_rss: f64,
    #[serde(rename = "loadedRssMiB")]
    loaded_rss: f64,
}
async fn live_dashboard(
    target: &BackendTarget,
    connection: &BankConnection,
    base: Option<&str>,
) -> ToolResult<(LiveSample, Vec<Value>)> {
    let api = uuid::Uuid::new_v4().to_string();
    let mut backend = BackendProcess::launch(target, &connection.handshake(&api, base)).await?;
    let startup = backend.startup_ms;
    let startup_rss = backend.resident_mib()?;
    let started = Instant::now();
    let data = load_bank_dashboard(&backend, &api, &dashboard_paths(benchmark_today())).await?;
    let dashboard = started.elapsed().as_secs_f64() * 1000.0;
    let loaded_rss = backend.resident_mib()?;
    backend.stop().await?;
    Ok((
        LiveSample {
            startup,
            dashboard,
            total: startup + dashboard,
            startup_rss,
            loaded_rss,
        },
        data,
    ))
}
const SECTIONS: [&str; 8] = [
    "accounts",
    "cashflow",
    "spending",
    "previous-spending",
    "recurring",
    "freshness",
    "transactions",
    "forecast",
];
async fn compare_runs(
    count: usize,
    targets: &[BackendTarget; 2],
    connection: &BankConnection,
    base: Option<&str>,
) -> ToolResult<Value> {
    let mut samples: [Vec<LiveSample>; 2] = [vec![], vec![]];
    let mut parity = vec![];
    for run in 0..count {
        let mut pair: [Vec<Value>; 2] = [vec![], vec![]];
        for index in if run % 2 == 0 { [0, 1] } else { [1, 0] } {
            let (sample, data) = live_dashboard(&targets[index], connection, base).await?;
            samples[index].push(sample);
            pair[index] = data;
        }
        let equal: Vec<_> = pair[0].iter().zip(&pair[1]).map(|(a, b)| a == b).collect();
        println!(
            "{}",
            json!({"mode":if base.is_some(){"real-data-replay"}else{"live-akahu"},"pair":run+1,"identicalSections":equal.iter().filter(|n|**n).count(),"sections":8})
        );
        parity.push(equal);
    }
    let mut implementations = serde_json::Map::new();
    for (name, rows) in ["typescript", "rust"].iter().zip(&samples) {
        implementations.insert((*name).into(),json!({"summary":{"startupMs":summarize_samples(rows.iter().map(|s|s.startup)),"dashboardMs":summarize_samples(rows.iter().map(|s|s.dashboard)),"startupAndDashboardMs":summarize_samples(rows.iter().map(|s|s.total)),"startupRssMiB":summarize_samples(rows.iter().map(|s|s.startup_rss)),"loadedRssMiB":summarize_samples(rows.iter().map(|s|s.loaded_rss))},"samples":rows}));
    }
    Ok(
        json!({"runsPerImplementation":count,"order":"Alternating pairs, TypeScript first in the first pair.","implementations":implementations,"parity":{"identicalPairs":parity.iter().filter(|p|p.len()==8 && p.iter().all(|n|*n)).count(),"sections":SECTIONS.iter().enumerate().map(|(index,name)|json!({"section":name,"identicalPairs":parity.iter().filter(|p|p.get(index)==Some(&true)).count()})).collect::<Vec<_>>()}}),
    )
}
type SnapshotPages = Arc<Mutex<HashMap<String, Zeroizing<Vec<u8>>>>>;
struct BankSnapshot {
    server: LoopbackServer,
    recording: Arc<AtomicBool>,
    _pages: SnapshotPages,
}
fn page_key(url: &reqwest::Url) -> String {
    let mut pairs: Vec<_> = url.query_pairs().into_owned().collect();
    pairs.sort();
    let mut sorted = url.clone();
    sorted.set_query(None);
    sorted.query_pairs_mut().extend_pairs(pairs);
    format!("{}?{}", sorted.path(), sorted.query().unwrap_or(""))
}
async fn snapshot_proxy(source: &str) -> ToolResult<BankSnapshot> {
    let pages: SnapshotPages = Arc::new(Mutex::new(HashMap::new()));
    let recording = Arc::new(AtomicBool::new(true));
    let (stored, active) = (pages.clone(), recording.clone());
    let source = reqwest::Url::parse(source)?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let routes = regex::Regex::new(r"^/v1/accounts(?:/[^/]+/transactions(?:/pending)?)?$")?;
    let server = LoopbackServer::start(move |request| {
        let (pages, recording, client, source, routes) = (
            stored.clone(),
            active.clone(),
            client.clone(),
            source.clone(),
            routes.clone(),
        );
        Box::pin(async move {
            if request.method != "GET" || !routes.is_match(request.url.path()) {
                return FixtureResponse::error(404, "");
            }
            let key = page_key(&request.url);
            if !recording.load(Ordering::Acquire) {
                return pages
                    .lock()
                    .expect("Bank snapshot page mutex is not poisoned")
                    .get(&key)
                    .map(|body| FixtureResponse {
                        status: 200,
                        body: body.to_vec(),
                        headers: vec![("Content-Type".into(), "application/json".into())],
                    })
                    .unwrap_or_else(|| FixtureResponse::error(502, ""));
            }
            let mut url = source;
            url.set_path(request.url.path());
            url.set_query(request.url.query());
            let mut outgoing = client.get(url).header("Accept", "application/json");
            for name in ["authorization", "x-akahu-id"] {
                if let Some(value) = request.headers.get(name) {
                    outgoing = outgoing.header(name, value);
                }
            }
            let Ok(response) = outgoing.send().await else {
                return FixtureResponse::error(502, "");
            };
            let status = response.status().as_u16();
            if status != 200 {
                return FixtureResponse::error(status, "");
            }
            let Ok(body) = response.bytes().await else {
                return FixtureResponse::error(502, "");
            };
            pages
                .lock()
                .expect("Bank snapshot page mutex is not poisoned")
                .insert(key, Zeroizing::new(body.to_vec()));
            FixtureResponse {
                status: 200,
                body: body.to_vec(),
                headers: vec![("Content-Type".into(), "application/json".into())],
            }
        })
    })
    .await?;
    Ok(BankSnapshot {
        server,
        recording,
        _pages: pages,
    })
}
fn write_private_report(path: &Path, value: &Value) -> ToolResult {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    writeln!(file, "{}", serde_json::to_string_pretty(value)?)?;
    Ok(())
}
/// Compare live read-only Akahu requests and RAM-only replay; persist only timings and equality counts.
pub async fn compare_live_backends(args: &[String]) -> ToolResult {
    let options = tool_options(
        args,
        &[
            "runs",
            "replay-runs",
            "baseline-bundle",
            "rust-bundle",
            "output",
        ],
        &[],
    )?;
    let runs = bounded_runs(&options, "runs", 5, 1, 30)?;
    let replay_runs = bounded_runs(&options, "replay-runs", 20, 1, 30)?;
    let baseline = options
        .get("baseline-bundle")
        .map(PathBuf::from)
        .unwrap_or_else(|| project_root().join(".build/typescript-baseline"));
    let rust = options
        .get("rust-bundle")
        .map(PathBuf::from)
        .unwrap_or_else(|| project_root().join("dist/Reckon.app"));
    let targets = [
        BackendTarget::historical_typescript(&baseline),
        BackendTarget::rust(&rust),
    ];
    let metadata = json!({"typescript":backend_binary_metadata(&targets[0])?,"rust":backend_binary_metadata(&targets[1])?});
    let connection = BankConnection::read_keychain()?;
    let live = compare_runs(runs, &targets, &connection, None).await?;
    let snapshot = snapshot_proxy("https://api.akahu.io").await?;
    let base = format!("{}/v1", snapshot.server.base_url);
    live_dashboard(&targets[1], &connection, Some(&base)).await?;
    snapshot.recording.store(false, Ordering::Release);
    let replay = compare_runs(replay_runs, &targets, &connection, Some(&base)).await?;
    drop(snapshot);
    let mut env = benchmark_environment();
    env["backends"] = metadata;
    let report = json!({"measuredAt":Utc::now().to_rfc3339(),"environment":env,"method":{"live":"Both backends read Akahu directly through the saved Keychain connection. Each fresh process loads eight dashboard requests. No bank refresh or write occurs.","replay":"A single Akahu capture stays only in RAM. Both backends replay identical source pages over loopback. The proxy never reaches Akahu after capture.","memory":"Backend RSS in MiB from ps after readiness and dashboard, outside timed phases. Excludes peak memory, harness and Swift app.","privacy":"Only timings, RSS, binary metadata, and equality counts enter the report. No credentials or bank records are saved.","limits":"Live results include source and network variation. Replay excludes external TLS and latency. This report uses a Rust harness; historical reports used Node."},"live":live,"replay":replay});
    let output = options
        .get("output")
        .map(PathBuf::from)
        .unwrap_or_else(|| project_root().join(".build/live-backend-comparison.json"));
    write_private_report(&output, &report)?;
    println!(
        "{}",
        json!({"complete":true,"live":report["live"]["implementations"],"replay":report["replay"]["implementations"],"parity":{"live":report["live"]["parity"],"replay":report["replay"]["parity"]}})
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::loopback_fixture::{AkahuFixture, AkahuFixtureState};
    #[tokio::test]
    async fn replay_uses_only_captured_pages_after_recording_stops() {
        let fixture = AkahuFixture::start(
            AkahuFixtureState::default(),
            "synthetic-app",
            "synthetic-user",
        )
        .await
        .unwrap();
        let proxy = snapshot_proxy(&fixture.server.base_url).await.unwrap();
        let url = format!("{}/v1/accounts", proxy.server.base_url);
        let client = reqwest::Client::new();
        let original = client
            .get(&url)
            .bearer_auth("synthetic-user")
            .header("X-Akahu-Id", "synthetic-app")
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        assert_eq!(fixture.state.lock().unwrap().calls.len(), 1);
        proxy.recording.store(false, Ordering::Release);
        drop(fixture);
        let replay = client
            .get(&url)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        assert_eq!(original, replay);
        assert_eq!(
            client
                .get(format!(
                    "{}/v1/accounts?cursor=missing",
                    proxy.server.base_url
                ))
                .send()
                .await
                .unwrap()
                .status(),
            502
        );
        assert_eq!(client.post(&url).send().await.unwrap().status(), 404);
    }
}
