use crate::backend_process::{BackendProcess, BackendTarget, load_bank_dashboard};
use crate::loopback_fixture::{AkahuFixture, AkahuFixtureState, fixture_transaction};
use crate::{ToolResult, command_output, project_root, tool_options};
use chrono::{Datelike, Duration, NaiveDate, Utc};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;
pub(crate) fn benchmark_today() -> NaiveDate {
    Utc::now()
        .with_timezone(&chrono_tz::Pacific::Auckland)
        .date_naive()
}
fn shift_month(date: NaiveDate, months: i32, day: Option<u32>) -> NaiveDate {
    let month = date.year() * 12 + date.month0() as i32 + months;
    NaiveDate::from_ymd_opt(month.div_euclid(12), month.rem_euclid(12) as u32 + 1, 1)
        .expect("Shifted benchmark month is within the supported calendar range")
        + Duration::days(day.unwrap_or(date.day()) as i64 - 1)
}
/// Build the same eight dashboard requests as the native app using Auckland calendar dates.
///
/// # Panics
/// Panics if the historical date range extends beyond Chrono's supported calendar range.
pub fn dashboard_paths(date: NaiveDate) -> Vec<String> {
    let first = date
        .with_day(1)
        .expect("A valid benchmark date has a first day of its month");
    let history = format!("from={}&to={date}", shift_month(date, -6, None));
    let current = format!("from={first}&to={date}&excludeTransfers=true");
    vec![
        "/accounts".into(),
        format!("/cashflow?{current}"),
        format!("/spending?{current}"),
        format!(
            "/spending?from={}&to={}&excludeTransfers=true",
            shift_month(date, -3, Some(1)),
            first - Duration::days(1)
        ),
        format!("/recurring?{history}"),
        "/freshness".into(),
        format!("/transactions?{history}&limit=100&excludeTransfers=true"),
        "/forecast?days=30&excludeTransfers=true".into(),
    ]
}
pub(crate) fn summarize_samples(values: impl Iterator<Item = f64>) -> Value {
    let mut values: Vec<_> = values.collect();
    values.sort_by(f64::total_cmp);
    let count = values.len();
    let mid = count / 2;
    json!({"median":if count%2==1{values[mid]}else{(values[mid-1]+values[mid])/2.0},"p95":values[(count as f64*0.95).ceil() as usize-1],"min":values[0],"max":values[count-1]})
}
pub(crate) fn bounded_runs(
    options: &BTreeMap<String, String>,
    name: &str,
    default: usize,
    min: usize,
    max: usize,
) -> ToolResult<usize> {
    let value = options
        .get(name)
        .map(|value| value.parse::<usize>())
        .transpose()?
        .unwrap_or(default);
    if !(min..=max).contains(&value) {
        return Err(format!("Use {min}–{max} {name}.").into());
    }
    Ok(value)
}
pub(crate) fn benchmark_environment() -> Value {
    let text = |program: &str, args: &[&str]| {
        command_output(Command::new(program).args(args), None)
            .ok()
            .map(|value| String::from_utf8_lossy(&value).trim().to_string())
            .unwrap_or_else(|| "unknown".into())
    };
    json!({"cpu":text("/usr/sbin/sysctl",&["-n","machdep.cpu.brand_string"]),"architecture":if cfg!(target_arch="aarch64"){"arm64"}else{"x86_64"},"platform":std::env::consts::OS,"kernel":text("/usr/bin/uname",&["-r"]),"harness":"Rust reckon-tools"})
}
pub(crate) fn backend_binary_metadata(target: &BackendTarget) -> ToolResult<Value> {
    let bytes = fs::read(&target.binary)?;
    Ok(json!({"sha256":format!("{:x}",Sha256::digest(&bytes)),"bytes":bytes.len()}))
}
fn synthetic_state(latency_ms: u64) -> AkahuFixtureState {
    let date = benchmark_today();
    let from = shift_month(date, -6, Some(1));
    let days = (date - from).num_days() + 1;
    let mut accounts = vec![];
    let mut transactions = vec![];
    for (account, kind) in ["CHECKING", "SAVINGS", "INVESTMENT"].iter().enumerate() {
        let id = format!("fixture_account_{account}");
        accounts.push(json!({"_id":id,"name":format!("Fixture account {account}"),"type":kind,"balance":{"current":1000+account*1000,"currency":"NZD"},"refreshed":{"balance":format!("{date}T00:00:00Z"),"transactions":format!("{date}T00:00:00Z")}}));
        for index in 0..1000 {
            let date = from + Duration::days(index % days);
            transactions.push(fixture_transaction(
                &format!("fixture_transaction_{account}_{index}"),
                &id,
                &date.to_string(),
                json!(if index % 29 == 0 {
                    1000.0
                } else {
                    -(5.0 + ((index * 37 + account as i64 * 13) % 30000) as f64 / 100.0)
                }),
                &format!("Fixture merchant {}", index % 35),
                &format!("Fixture category {}", index % 8),
            ));
        }
    }
    AkahuFixtureState {
        accounts,
        transactions,
        page_size: 500,
        account_page_size: usize::MAX,
        latency_ms,
        ..Default::default()
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DashboardLoad {
    elapsed_ms: f64,
    upstream_requests: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SyntheticSample {
    startup_ms: f64,
    startup_rss_mi_b: f64,
    first_load: DashboardLoad,
    loaded_rss_mi_b: f64,
    reload: DashboardLoad,
    reload_rss_mi_b: f64,
}
// Use the report's existing RSS spelling rather than serde's MiB word splitting.
fn synthetic_sample_json(sample: &SyntheticSample) -> Value {
    json!({"startupMs":sample.startup_ms,"startupRssMiB":sample.startup_rss_mi_b,"firstLoad":sample.first_load,"loadedRssMiB":sample.loaded_rss_mi_b,"reload":sample.reload,"reloadRssMiB":sample.reload_rss_mi_b})
}
async fn synthetic_load(
    backend: &BackendProcess,
    paths: &[String],
    fixture: &AkahuFixture,
) -> ToolResult<DashboardLoad> {
    let calls = fixture
        .state
        .lock()
        .expect("Akahu fixture state mutex is not poisoned")
        .calls
        .len();
    let started = Instant::now();
    let data = load_bank_dashboard(backend, "synthetic-benchmark-token", paths).await?;
    if data[0].as_array().map(Vec::len) != Some(3)
        || data[6].as_array().map(Vec::len) != Some(100)
        || data[7]["points"].as_array().map(Vec::len) != Some(31)
    {
        return Err("Synthetic dashboard shape changed.".into());
    }
    Ok(DashboardLoad {
        elapsed_ms: started.elapsed().as_secs_f64() * 1000.0,
        upstream_requests: fixture
            .state
            .lock()
            .expect("Akahu fixture state mutex is not poisoned")
            .calls
            .len()
            - calls,
    })
}
/// Measure fresh backend processes and warm reloads against 3,000 fictional transactions.
pub async fn measure_backend(args: &[String]) -> ToolResult {
    let options = tool_options(
        args,
        &[
            "runs",
            "output",
            "bundle",
            "implementation",
            "max-loaded-rss-mib",
        ],
        &[],
    )?;
    let runs = bounded_runs(&options, "runs", 20, 2, 100)?;
    let implementation = options
        .get("implementation")
        .map(String::as_str)
        .unwrap_or("rust");
    let bundle = options
        .get("bundle")
        .map(PathBuf::from)
        .unwrap_or_else(|| project_root().join("dist/Reckon.app"));
    let target = match implementation {
        "rust" => BackendTarget::rust(&bundle),
        "typescript" => BackendTarget::historical_typescript(&bundle),
        _ => return Err("Use rust or typescript.".into()),
    };
    let max_rss = options
        .get("max-loaded-rss-mib")
        .map(|v| v.parse::<f64>())
        .transpose()?;
    if max_rss.is_some_and(|n| !n.is_finite() || n <= 0.0) {
        return Err("Use a positive RSS limit in MiB.".into());
    }
    let paths = dashboard_paths(benchmark_today());
    let mut scenarios = vec![];
    for latency in [0, 50] {
        let fixture = AkahuFixture::start(
            synthetic_state(latency),
            "synthetic-benchmark-token",
            "synthetic-benchmark-token",
        )
        .await?;
        let mut samples = vec![];
        for _ in 0..runs {
            let mut backend=BackendProcess::launch(&target,&json!({"appToken":"synthetic-benchmark-token","userToken":"synthetic-benchmark-token","apiToken":"synthetic-benchmark-token","akahuBaseURL":fixture.base_url()})).await?;
            let startup_ms = backend.startup_ms;
            let startup_rss_mi_b = backend.resident_mib()?;
            let first_load = synthetic_load(&backend, &paths, &fixture).await?;
            let loaded_rss_mi_b = backend.resident_mib()?;
            let reload = synthetic_load(&backend, &paths, &fixture).await?;
            let reload_rss_mi_b = backend.resident_mib()?;
            backend.stop().await?;
            samples.push(SyntheticSample {
                startup_ms,
                startup_rss_mi_b,
                first_load,
                loaded_rss_mi_b,
                reload,
                reload_rss_mi_b,
            });
        }
        let median_rss = summarize_samples(samples.iter().map(|s| s.loaded_rss_mi_b));
        if max_rss.is_some_and(|limit| {
            median_rss["median"]
                .as_f64()
                .expect("Nonempty benchmark samples produce a numeric median")
                > limit
        }) {
            return Err("Loaded backend RSS exceeds the requested limit.".into());
        }
        let first_calls: std::collections::BTreeSet<_> = samples
            .iter()
            .map(|s| s.first_load.upstream_requests)
            .collect();
        let reload_calls: std::collections::BTreeSet<_> =
            samples.iter().map(|s| s.reload.upstream_requests).collect();
        let metrics = json!({"startupMs":summarize_samples(samples.iter().map(|s|s.startup_ms)),"firstDashboardMs":summarize_samples(samples.iter().map(|s|s.first_load.elapsed_ms)),"startupAndDashboardMs":summarize_samples(samples.iter().map(|s|s.startup_ms+s.first_load.elapsed_ms)),"freshReloadMs":summarize_samples(samples.iter().map(|s|s.reload.elapsed_ms)),"startupRssMiB":summarize_samples(samples.iter().map(|s|s.startup_rss_mi_b)),"loadedRssMiB":median_rss,"reloadRssMiB":summarize_samples(samples.iter().map(|s|s.reload_rss_mi_b)),"firstLoadUpstreamRequests":first_calls,"reloadUpstreamRequests":reload_calls});
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"latencyMs":latency,"runs":runs,"summary":metrics})
            )?
        );
        scenarios.push(json!({"latencyMs":latency,"runs":runs,"summary":metrics,"samples":samples.iter().map(synthetic_sample_json).collect::<Vec<_>>()}));
    }
    if let Some(path) = options.get("output") {
        let mut env = benchmark_environment();
        env["implementation"] = json!(implementation);
        let metadata = backend_binary_metadata(&target)?;
        env["bundleBytes"] = metadata["bytes"].clone();
        env["bundleSha256"] = metadata["sha256"].clone();
        env["runtimeArguments"] = if implementation == "rust" {
            json!([])
        } else {
            json!(["--max-semi-space-size=2", "<backend.cjs>"])
        };
        let mut version_command = if implementation == "rust" {
            Command::new("rustc")
        } else {
            Command::new(&target.executable)
        };
        env["toolchain"] = json!(
            String::from_utf8(command_output(version_command.arg("--version"), None)?)?.trim()
        );
        let report = json!({"measuredAt":Utc::now().to_rfc3339(),"environment":env,"workload":{"accounts":3,"postedTransactions":3000,"pageSize":500,"dashboardRequests":8,"from":shift_month(benchmark_today(),-6,Some(1)).to_string(),"to":benchmark_today().to_string()},"method":{"startup":"Fresh child through ready handshake; OS caches are not flushed.","dashboard":"Eight concurrent authenticated requests through JSON decoding in the Rust harness. Each load uses a fresh snapshot UUID. Excludes Swift, Keychain, and live Akahu.","lifecycle":"startupAndDashboardMs sums startup and first dashboard time, excluding RSS sampling. Warm reloads are supplemental.","memory":"Backend RSS from ps in MiB, outside timed phases. Excludes peak RSS and the Swift app.","latency":"Loopback fixture delays each source response by 0 or 50 ms. This is not live Akahu performance."},"scenarios":scenarios});
        fs::write(
            path,
            format!("{}\n", serde_json::to_string_pretty(&report)?),
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn benchmark_statistics_and_month_overflow_preserve_report_semantics() {
        assert_eq!(
            summarize_samples([1.0, 4.0, 2.0, 3.0].into_iter())["median"],
            2.5
        );
        assert_eq!(
            shift_month(NaiveDate::from_ymd_opt(2026, 10, 31).unwrap(), -6, None),
            NaiveDate::from_ymd_opt(2026, 5, 1).unwrap()
        );
        assert_eq!(dashboard_paths(benchmark_today()).len(), 8);
    }
}
