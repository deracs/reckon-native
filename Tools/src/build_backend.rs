use crate::{ToolResult, command_output, project_root, run_visible};
use regex::Regex;
use serde_json::Value;
use std::{collections::HashSet, env, fs, path::Path, process::Command};

/// Build the distributable backend with source paths remapped and dependency license notices.
pub fn build_backend() -> ToolResult {
    let root = project_root();
    run_visible(Command::new("cargo").args([
        "build",
        "--manifest-path",
        "Tools/Cargo.toml",
        "--locked",
        "--bin",
        "reckon-backend-fixture",
    ]))?;
    let home = env::var("HOME")?;
    let flags = format!(
        "{} --remap-path-prefix={}=/reckon-native --remap-path-prefix={home}/.cargo=/cargo",
        env::var("RUSTFLAGS").unwrap_or_default(),
        root.display()
    );
    let configure = || {
        let mut command = Command::new("cargo");
        command
            .current_dir(&root)
            .env("CARGO_TARGET_DIR", root.join(".build/rust"))
            .env("RUSTFLAGS", &flags);
        command
    };
    run_visible(configure().args([
        "build",
        "--manifest-path",
        "Backend/Cargo.toml",
        "--release",
        "--locked",
    ]))?;
    let rustc = String::from_utf8(command_output(Command::new("rustc").arg("-vV"), None)?)?;
    let host = rustc
        .lines()
        .find_map(|line| line.strip_prefix("host: "))
        .ok_or("Rust host triple missing.")?;
    let metadata: Value = serde_json::from_slice(&command_output(
        configure().args([
            "metadata",
            "--manifest-path",
            "Backend/Cargo.toml",
            "--locked",
            "--format-version",
            "1",
            "--filter-platform",
            host,
        ]),
        None,
    )?)?;
    let compiled: HashSet<&str> = metadata["resolve"]["nodes"]
        .as_array()
        .ok_or("Cargo dependency graph missing.")?
        .iter()
        .filter_map(|node| node["id"].as_str())
        .collect();
    let license_pattern = Regex::new(r"(?i)^(licen[sc]e|copying|notice)([.-]|$)")?;
    let mut notices = Vec::new();
    for dependency in metadata["packages"]
        .as_array()
        .ok_or("Cargo packages missing.")?
    {
        if dependency["source"].is_null()
            || !compiled.contains(dependency["id"].as_str().unwrap_or(""))
        {
            continue;
        }
        let directory = Path::new(
            dependency["manifest_path"]
                .as_str()
                .ok_or("Cargo manifest path missing.")?,
        )
        .parent()
        .ok_or("Cargo package directory missing.")?;
        let mut licenses: Vec<_> = fs::read_dir(directory)?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| license_pattern.is_match(&path.file_name().unwrap().to_string_lossy()))
            .collect();
        if let Some(file) = dependency["license_file"].as_str() {
            let file = directory.join(file);
            if !licenses.contains(&file) {
                licenses.push(file);
            }
        }
        licenses.sort();
        let mut texts = Vec::new();
        for file in licenses {
            if file.is_file() {
                texts.push(fs::read_to_string(file)?);
            }
        }
        if texts.is_empty() {
            return Err(format!(
                "Backend dependency license text missing for {}.",
                dependency["name"]
            )
            .into());
        }
        notices.push(format!(
            "{}@{} ({})\n{}",
            dependency["name"].as_str().unwrap_or("unknown"),
            dependency["version"].as_str().unwrap_or("unknown"),
            dependency["license"].as_str().unwrap_or("see license"),
            texts.join("\n")
        ));
    }
    let directory = root.join(".build/backend");
    fs::create_dir_all(&directory)?;
    fs::write(
        directory.join("THIRD-PARTY-NOTICES.txt"),
        notices.join("\n\n"),
    )?;
    Ok(())
}
