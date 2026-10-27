pub mod backend_benchmark;
pub mod backend_process;
pub mod build_backend;
pub mod live_backend_comparison;
pub mod loopback_fixture;
pub mod release_privacy;
pub mod release_updates;

use std::error::Error;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
pub type ToolResult<T = ()> = Result<T, Box<dyn Error + Send + Sync>>;

/// Locate repository files without depending on the caller's working directory.
pub fn project_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("Tools manifest directory has a repository parent")
        .to_path_buf()
}

/// Capture command output while keeping subprocess diagnostics out of secret-bearing errors.
pub fn command_output(command: &mut Command, input: Option<&[u8]>) -> ToolResult<Vec<u8>> {
    let mut child = command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if let Some(input) = input {
        let delivery = child
            .stdin
            .take()
            .ok_or_else(|| std::io::Error::other("Command stdin unavailable"))
            .and_then(|mut pipe| pipe.write_all(input));
        if let Err(error) = delivery {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error.into());
        }
    }
    let result = child.wait_with_output()?;
    if !result.status.success() {
        return Err("Tool subprocess failed; output withheld to protect credentials.".into());
    }
    Ok(result.stdout)
}

/// Run a development command with visible diagnostics; never pass credentials to this helper.
pub fn run_visible(command: &mut Command) -> ToolResult {
    if !command.status()?.success() {
        return Err("Development command failed.".into());
    }
    Ok(())
}

/// Parse named CLI options and reject missing values, duplicates, and unknown arguments.
pub fn tool_options(
    args: &[String],
    names: &[&str],
    flags: &[&str],
) -> ToolResult<std::collections::BTreeMap<String, String>> {
    let mut result = std::collections::BTreeMap::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let name = arg.strip_prefix("--").ok_or("Expected a named option.")?;
        let value = if flags.contains(&name) {
            String::new()
        } else if names.contains(&name) {
            args.next()
                .filter(|v| !v.starts_with("--"))
                .ok_or("Option requires a value.")?
                .clone()
        } else {
            return Err(format!("Unknown option: --{name}").into());
        };
        if result.insert(name.to_string(), value).is_some() {
            return Err("Duplicate option.".into());
        }
    }
    Ok(result)
}
