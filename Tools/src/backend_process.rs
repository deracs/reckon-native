use crate::{ToolResult, command_output};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::task::JoinHandle;

/// Select a standalone backend, or an explicitly supplied historical TypeScript bundle.
#[derive(Clone)]
pub struct BackendTarget {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub binary: PathBuf,
}
impl BackendTarget {
    pub fn rust(bundle: &Path) -> Self {
        let executable = bundle.join("Contents/Helpers/reckon-backend");
        Self {
            binary: executable.clone(),
            executable,
            arguments: vec![],
        }
    }
    pub fn historical_typescript(bundle: &Path) -> Self {
        let binary = bundle.join("Contents/Resources/Backend/backend.cjs");
        Self {
            executable: bundle.join("Contents/Helpers/node"),
            arguments: vec![
                "--max-semi-space-size=2".into(),
                binary.to_string_lossy().into_owned(),
            ],
            binary,
        }
    }
}

/// Own a child backend, its private stdin pipe, and bounded captured diagnostics.
pub struct BackendProcess {
    pub child: Child,
    pub ready: Value,
    pub startup_ms: f64,
    _directory: TempDir,
    output: Option<JoinHandle<Vec<u8>>>,
    errors: Option<JoinHandle<Vec<u8>>>,
    first_line: Vec<u8>,
}
impl BackendProcess {
    pub async fn launch(target: &BackendTarget, handshake: &Value) -> ToolResult<Self> {
        let directory = tempfile::tempdir()?;
        let started = Instant::now();
        let mut child = tokio::process::Command::new(&target.executable)
            .args(&target.arguments)
            .current_dir(directory.path())
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("TZ", "Pacific/Auckland")
            .env("LANG", "en_NZ.UTF-8")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let mut stdout = BufReader::new(child.stdout.take().ok_or("Backend stdout unavailable.")?);
        let mut stderr = child.stderr.take().ok_or("Backend stderr unavailable.")?;
        let errors = tokio::spawn(async move {
            let mut bytes = Vec::new();
            let _ = (&mut stderr).take(65536).read_to_end(&mut bytes).await;
            bytes
        });
        let mut input = serde_json::to_vec(handshake)?;
        input.push(b'\n');
        child
            .stdin
            .as_mut()
            .ok_or("Backend stdin unavailable.")?
            .write_all(&input)
            .await?;
        let mut first_line = Vec::new();
        let read = tokio::time::timeout(
            Duration::from_secs(12),
            (&mut stdout).take(16385).read_until(b'\n', &mut first_line),
        )
        .await;
        if !matches!(read, Ok(Ok(1..))) || first_line.len() > 16384 {
            return Err("Backend failed its startup protocol.".into());
        }
        let ready = serde_json::from_slice(&first_line)
            .map_err(|_| "Backend sent invalid startup output.")?;
        let output = tokio::spawn(async move {
            let mut bytes = Vec::new();
            let _ = stdout.take(65536).read_to_end(&mut bytes).await;
            bytes
        });
        Ok(Self {
            child,
            ready,
            startup_ms: started.elapsed().as_secs_f64() * 1000.0,
            _directory: directory,
            output: Some(output),
            errors: Some(errors),
            first_line,
        })
    }
    pub fn base_url(&self) -> ToolResult<String> {
        let port = self.ready["port"]
            .as_u64()
            .filter(|p| (1..=65535).contains(p))
            .ok_or("Backend did not become ready.")?;
        if self.ready["event"] != "ready" {
            return Err("Backend did not become ready.".into());
        }
        Ok(format!("http://127.0.0.1:{port}"))
    }
    pub async fn stop(&mut self) -> ToolResult<std::process::ExitStatus> {
        self.child.stdin.take();
        match tokio::time::timeout(Duration::from_secs(4), self.child.wait()).await {
            Ok(result) => Ok(result?),
            Err(_) => {
                self.child.kill().await?;
                Err("Backend shutdown timed out.".into())
            }
        }
    }
    pub async fn assert_no_secret_output(&mut self, secrets: &[&str]) -> ToolResult {
        let mut bytes = self.first_line.clone();
        for task in [&mut self.output, &mut self.errors] {
            if let Some(task) = task.take() {
                bytes.extend(task.await?);
            }
        }
        if secrets.iter().any(|secret| {
            !secret.is_empty()
                && bytes
                    .windows(secret.len())
                    .any(|value| value == secret.as_bytes())
        }) {
            return Err("Backend diagnostics exposed a credential.".into());
        }
        Ok(())
    }
    pub fn resident_mib(&self) -> ToolResult<f64> {
        let pid = self.child.id().ok_or("Backend process already exited.")?;
        let output = command_output(
            Command::new("/bin/ps").args(["-o", "rss=", "-p", &pid.to_string()]),
            None,
        )?;
        Ok(std::str::from_utf8(&output)?.trim().parse::<f64>()? / 1024.0)
    }
}

/// Fetch dashboard sections concurrently under one snapshot UUID, preserving response order.
pub async fn load_bank_dashboard(
    backend: &BackendProcess,
    api_token: &str,
    paths: &[String],
) -> ToolResult<Vec<Value>> {
    let base = backend.base_url()?;
    let snapshot = uuid::Uuid::new_v4().to_string();
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(120))
        .build()?;
    let requests = paths.iter().map(|path| {
        let client = &client;
        let base = &base;
        let snapshot = &snapshot;
        async move {
            let response = client
                .get(format!("{base}{path}"))
                .bearer_auth(api_token)
                .header("X-Reckon-Snapshot", snapshot)
                .send()
                .await?;
            if !response.status().is_success() {
                return Err("Dashboard section failed; source details withheld.".into());
            }
            Ok(response.json().await?)
        }
    });
    futures_util::future::try_join_all(requests).await
}
