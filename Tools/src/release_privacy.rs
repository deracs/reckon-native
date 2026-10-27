use crate::{ToolResult, command_output, project_root, tool_options};
use regex::bytes::Regex;
use serde_json::json;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};
use zeroize::Zeroizing;

fn parse_env(contents: &str) -> ToolResult<HashMap<String, String>> {
    let key_pattern = regex::Regex::new(r"^[A-Za-z_][A-Za-z0-9_]*$")?;
    let mut values = HashMap::new();
    let mut lines = contents.lines();
    while let Some(line) = lines.next() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line).trim_start();
        let Some((key, raw)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !key_pattern.is_match(key) {
            return Err("Invalid env variable name; contents withheld.".into());
        }
        let raw = raw.trim_start();
        let value = if let Some(quote) = raw
            .chars()
            .next()
            .filter(|ch| ['\"', '\'', '`'].contains(ch))
        {
            let mut remaining = raw[1..].to_string();
            loop {
                let mut escaped = false;
                let end = remaining.char_indices().find_map(|(index, ch)| {
                    if ch == quote && !escaped {
                        return Some(index);
                    }
                    escaped = ch == '\\' && !escaped;
                    None
                });
                if let Some(end) = end {
                    let tail = remaining[end + 1..].trim();
                    if !tail.is_empty() && !tail.starts_with('#') {
                        return Err("Invalid quoted env value; contents withheld.".into());
                    }
                    let value = remaining[..end].to_string();
                    break if quote == '\"' {
                        value.replace("\\n", "\n").replace("\\r", "\r")
                    } else {
                        value
                    };
                }
                remaining.push('\n');
                remaining.push_str(
                    lines
                        .next()
                        .ok_or("Unterminated env value; contents withheld.")?,
                );
            }
        } else {
            raw.split('#').next().unwrap_or("").trim().to_string()
        };
        values.insert(key.to_string(), value);
    }
    Ok(values)
}

fn read_env(path: &Path) -> ToolResult<HashMap<String, String>> {
    let contents = Zeroizing::new(fs::read_to_string(path)?);
    parse_env(&contents)
}

/// Import only Akahu tokens through the signed app's stdin; never print secret values.
pub fn import_akahu_credentials(args: &[String]) -> ToolResult {
    let result = (|| -> ToolResult {
        if !(1..=2).contains(&args.len()) {
            return Err("Invalid import arguments.".into());
        }
        let values = read_env(Path::new(&args[0]))?;
        let app = values
            .get("AKAHU_APP_TOKEN")
            .filter(|v| !v.trim().is_empty())
            .ok_or("Missing token.")?;
        let user = values
            .get("AKAHU_USER_TOKEN")
            .filter(|v| !v.trim().is_empty())
            .ok_or("Missing token.")?;
        let bundle = args
            .get(1)
            .map(PathBuf::from)
            .unwrap_or_else(|| project_root().join("dist/Reckon.app"));
        let input = Zeroizing::new(serde_json::to_vec(
            &json!({"appToken":app,"userToken":user}),
        )?);
        command_output(
            Command::new(bundle.join("Contents/MacOS/Reckon")).arg("--import-akahu-credentials"),
            Some(&input),
        )?;
        Ok(())
    })();
    result.map_err(
        |_| "Could not import Akahu tokens. Check the env path, token fields, and Keychain access.",
    )?;
    println!("Akahu tokens imported into Reckon's Keychain entry.");
    Ok(())
}

struct PrivacyInspector {
    secrets: Vec<Zeroizing<Vec<u8>>>,
    home: Option<Vec<u8>>,
    patterns: Vec<(&'static str, Regex)>,
    issues: Vec<String>,
}
impl PrivacyInspector {
    fn new(secrets: Vec<Zeroizing<Vec<u8>>>) -> ToolResult<Self> {
        let home = env::var("HOME").unwrap_or_default();
        Ok(Self {
            secrets,
            home: if home.len() > 6 && home != "/Users/runner" && home != "/home/runner" {
                Some(home.into_bytes())
            } else {
                None
            },
            issues: vec![],
            patterns: vec![
                (
                    "Akahu credential",
                    Regex::new(r"\b(?:app_token|user_token)_[A-Za-z0-9]{24,}\b")?,
                ),
                (
                    "GitHub credential",
                    Regex::new(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b")?,
                ),
                (
                    "NZ bank account number",
                    Regex::new(r"\b[0-9]{2}-[0-9]{4}-[0-9]{7}-[0-9]{2,3}\b")?,
                ),
                (
                    "private key",
                    Regex::new(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")?,
                ),
                (
                    "live Akahu account or transaction ID",
                    Regex::new(r"\b(?:acc|trans)_[a-zA-Z0-9]{16,}\b")?,
                ),
            ],
        })
    }
    fn inspect(&mut self, label: &str, bytes: &[u8]) {
        let includes = |needle: &[u8]| {
            !needle.is_empty() && bytes.windows(needle.len()).any(|part| part == needle)
        };
        if self.secrets.iter().any(|secret| includes(secret)) {
            self.issues.push(format!("{label}: matches a saved secret"));
        }
        if self.home.as_ref().is_some_and(|home| includes(home)) {
            self.issues.push(format!("{label}: personal home path"));
        }
        for (name, pattern) in &self.patterns {
            if pattern.is_match(bytes) {
                self.issues.push(format!("{label}: {name}"));
            }
        }
    }
    fn inspect_bundle(&mut self, root: &Path, directory: &Path) -> ToolResult {
        let private = Regex::new(
            r"(?i)^\.env(?:\.|$)|\.(?:enc|sqlite|sqlite3|db|p12|pfx|pem|key|mobileprovision|log)$",
        )?;
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let path = entry.path();
            let kind = entry.file_type()?;
            let relative = path.strip_prefix(root)?.to_string_lossy();
            let label = format!("app/{relative}");
            if kind.is_dir() {
                self.inspect_bundle(root, &path)?;
            } else if kind.is_symlink() {
                let target = fs::canonicalize(&path)?;
                if !target.starts_with(root)
                    || !relative.starts_with("Contents/Frameworks/Sparkle.framework/")
                {
                    self.issues.push(format!("{label}: unsafe symbolic link"));
                }
            } else {
                self.inspect(&label, &fs::read(&path)?);
            }
            if private.is_match(entry.file_name().to_string_lossy().as_bytes()) {
                self.issues.push(format!("{label}: private file"));
            }
        }
        Ok(())
    }
}

/// Inspect the Git index or working tree and app bundle without exposing matched private values.
pub fn check_release_privacy(args: &[String]) -> ToolResult {
    let options = tool_options(args, &["env-file", "signing-key-file", "app"], &["staged"])?;
    let mut secrets = Vec::new();
    if let Some(path) = options.get("env-file") {
        for (key, value) in read_env(Path::new(path))? {
            if ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "DATABASE_URL"]
                .iter()
                .any(|needle| key.contains(needle))
                && value.len() >= 12
            {
                secrets.push(Zeroizing::new(value.into_bytes()));
            }
        }
    }
    if let Ok(key) = env::var("SPARKLE_PRIVATE_KEY")
        && !key.trim().is_empty()
    {
        secrets.push(Zeroizing::new(key.trim().as_bytes().to_vec()));
    }
    if let Some(path) = options.get("signing-key-file") {
        let key = Zeroizing::new(fs::read_to_string(path)?);
        if key.trim().is_empty() {
            return Err("Privacy check requires a nonempty signing key.".into());
        }
        secrets.push(Zeroizing::new(key.trim().as_bytes().to_vec()));
    }
    let mut inspector = PrivacyInspector::new(secrets)?;
    let files = command_output(
        Command::new("git")
            .args(["ls-files", "-z"])
            .current_dir(project_root()),
        None,
    )?;
    let generated = Regex::new(
        r"(?i)(?:^|/)(?:\.env(?:\..*)?|node_modules|\.build|dist|\.swiftpm|\.DS_Store|target)(?:/|$)|\.(?:enc|sqlite|sqlite3|db|p12|pfx|pem|key|mobileprovision|zip|dmg|log)$|\.app/",
    )?;
    let mut inspected = 0;
    for file in files
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
    {
        let file = std::str::from_utf8(file)?;
        let bytes = if options.contains_key("staged") {
            command_output(
                Command::new("git")
                    .args(["show", &format!(":{file}")])
                    .current_dir(project_root()),
                None,
            )?
        } else {
            match fs::read(project_root().join(file)) {
                Ok(bytes) => bytes,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e.into()),
            }
        };
        if generated.is_match(file.as_bytes()) {
            inspector.issues.push(format!(
                "{file}: private or generated file must not be tracked"
            ));
        }
        inspector.inspect(file, &bytes);
        inspected += 1;
    }
    if let Some(path) = options.get("app") {
        let app = fs::canonicalize(path)?;
        inspector.inspect_bundle(&app, &app)?;
    }
    if !inspector.issues.is_empty() {
        return Err(format!(
            "Release privacy check failed:\n{}",
            inspector.issues.join("\n")
        )
        .into());
    }
    println!(
        "Release privacy check passed: {inspected} tracked files{}. Values were not printed.",
        if options.contains_key("app") {
            " and app bundle"
        } else {
            ""
        }
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn env_tokens_remain_literal_without_shell_or_environment_expansion() {
        let values = parse_env("export AKAHU_APP_TOKEN='$literal#token'\nAKAHU_USER_TOKEN=plain # comment\nMULTILINE=\"first\\nsecond\"\nBACKTICK=`literal$(value)`\n").unwrap();
        assert_eq!(values["AKAHU_APP_TOKEN"], "$literal#token");
        assert_eq!(values["AKAHU_USER_TOKEN"], "plain");
        assert_eq!(values["MULTILINE"], "first\nsecond");
        assert_eq!(values["BACKTICK"], "literal$(value)");
        assert!(parse_env("KEY='unfinished").is_err());
    }
    #[test]
    fn bundle_privacy_rejects_private_files_and_escaping_symlinks() {
        use std::os::unix::fs::symlink;
        let directory = tempfile::tempdir().unwrap();
        let bundle = directory.path().join("Fixture.app");
        let resources = bundle.join("Contents/Resources");
        fs::create_dir_all(&resources).unwrap();
        fs::write(resources.join(".env"), "synthetic-private-value").unwrap();
        let outside = directory.path().join("outside.txt");
        fs::write(&outside, "fixture").unwrap();
        symlink(&outside, resources.join("escape")).unwrap();
        let root = fs::canonicalize(&bundle).unwrap();
        let mut inspector = PrivacyInspector::new(vec![]).unwrap();
        inspector.inspect_bundle(&root, &root).unwrap();
        assert!(
            inspector
                .issues
                .iter()
                .any(|issue| issue.ends_with(": private file"))
        );
        assert!(
            inspector
                .issues
                .iter()
                .any(|issue| issue.ends_with(": unsafe symbolic link"))
        );
    }
    #[test]
    fn privacy_matches_binary_secrets_and_reports_only_labels() {
        let secret = Zeroizing::new(b"synthetic-private-value".to_vec());
        let mut inspector = PrivacyInspector::new(vec![secret]).unwrap();
        inspector.inspect("fixture", b"\xffsynthetic-private-value\0");
        assert_eq!(inspector.issues, vec!["fixture: matches a saved secret"]);
    }
    #[test]
    fn privacy_detects_each_credential_pattern() {
        let mut inspector = PrivacyInspector::new(vec![]).unwrap();
        for value in [
            format!("app_token_{}", "a".repeat(24)),
            format!("ghp_{}", "a".repeat(30)),
            format!("{}-{}-{}-{}", "00", "0000", "0000000", "00"),
            ["-----BEGIN ", "PRIVATE KEY-----"].concat(),
            format!("trans_{}", "a".repeat(16)),
        ] {
            inspector.inspect("fixture", value.as_bytes());
        }
        assert_eq!(inspector.issues.len(), 5);
    }
}
