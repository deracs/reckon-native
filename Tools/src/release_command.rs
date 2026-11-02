use crate::{ToolResult, command_output, project_root, run_visible, tool_options};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use regex::Regex;
use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

const REPOSITORY: &str = "deracs/reckon-native";
const WORKFLOW: &str = "macos-release.yml";
const NOTES: &str = ".github/release-notes.md";
const USAGE: &str = "Usage: cargo reckon release <patch|minor|major|X.Y.Z> --notes FILE [--dry-run]\n       cargo reckon release X.Y.Z --resume [--dry-run]\n\nRequires clean main, origin/main, and authenticated gh. Notes can live in .build/.\nRuns local checks, commits the version and notes, pushes main and an annotated tag,\nwaits for GitHub publication, checks release assets and feeds, then syncs main.\n--dry-run previews the release without changes. --resume continues an existing tag.";

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct ReleaseVersion {
    major: u64,
    minor: u64,
    patch: u64,
}

impl ReleaseVersion {
    fn parse(text: &str) -> ToolResult<Self> {
        let mut parts = text.strip_prefix('v').unwrap_or(text).split('.');
        let mut component = || -> ToolResult<u64> {
            let value = parts.next().ok_or("Release version needs three numbers.")?;
            if value.is_empty()
                || !value.bytes().all(|b| b.is_ascii_digit())
                || (value.len() > 1 && value.starts_with('0'))
            {
                return Err("Release version must use X.Y.Z without leading zeros.".into());
            }
            Ok(value.parse()?)
        };
        let version = Self {
            major: component()?,
            minor: component()?,
            patch: component()?,
        };
        if parts.next().is_some() {
            return Err("Release version must use X.Y.Z.".into());
        }
        Ok(version)
    }

    fn next(self, selector: &str) -> ToolResult<Self> {
        let increment = |n: u64| n.checked_add(1).ok_or("Release version overflow.");
        let version = match selector {
            "patch" => Self {
                patch: increment(self.patch)?,
                ..self
            },
            "minor" => Self {
                minor: increment(self.minor)?,
                patch: 0,
                ..self
            },
            "major" => Self {
                major: increment(self.major)?,
                minor: 0,
                patch: 0,
            },
            text => Self::parse(text)?,
        };
        if version <= self {
            return Err("Release version must be newer than the current version.".into());
        }
        Ok(version)
    }
}

impl fmt::Display for ReleaseVersion {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

struct ReleaseEdit {
    path: &'static str,
    original: String,
    replacement: String,
}

struct ReleasePlan {
    version: ReleaseVersion,
    build: u64,
    edits: Vec<ReleaseEdit>,
}

impl ReleasePlan {
    fn tag(&self) -> String {
        format!("v{}", self.version)
    }
}

struct ReleaseRunner {
    root: PathBuf,
    #[cfg(test)]
    path_override: Option<std::ffi::OsString>,
    #[cfg(test)]
    origin_override: Option<String>,
}

/// Release a clean main checkout through local checks and the signed GitHub release workflow.
pub fn run_release(args: &[String]) -> ToolResult {
    ReleaseRunner {
        root: project_root(),
        #[cfg(test)]
        path_override: None,
        #[cfg(test)]
        origin_override: None,
    }
    .release(args)
}

impl ReleaseRunner {
    fn command(&self, program: &str, args: &[&str]) -> Command {
        let mut command = Command::new(program);
        command
            .current_dir(&self.root)
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GH_PROMPT_DISABLED", "1")
            .env("GH_HOST", "github.com")
            .env_remove("GH_REPO");
        #[cfg(test)]
        if let Some(path) = &self.path_override {
            command.env("PATH", path);
        }
        command
    }

    fn capture(&self, program: &str, args: &[&str]) -> ToolResult<String> {
        Ok(String::from_utf8(command_output(
            &mut self.command(program, args),
            None,
        )?)?)
    }

    fn visible(&self, label: &str, program: &str, args: &[&str]) -> ToolResult {
        println!("[release] {label}");
        run_visible(&mut self.command(program, args))
            .map_err(|_| format!("Release step failed: {label}.").into())
    }

    fn git(&self, args: &[&str]) -> ToolResult<String> {
        self.capture("git", args)
    }

    fn github(&self, endpoint: &str) -> ToolResult<Value> {
        Ok(serde_json::from_str(&self.capture(
            "gh",
            &["api", &format!("repos/{REPOSITORY}/{endpoint}")],
        )?)?)
    }

    fn require_clean(&self) -> ToolResult {
        if !self
            .git(&["status", "--porcelain", "--untracked-files=all"])?
            .is_empty()
        {
            return Err("Release requires a clean working tree. Commit or stash changes first; keep release notes in .build/.".into());
        }
        Ok(())
    }

    fn preflight(&self, dry_run: bool) -> ToolResult {
        self.require_clean()?;
        if self.git(&["branch", "--show-current"])?.trim() != "main" {
            return Err("Release requires the main branch.".into());
        }
        let origin = self.git(&["remote", "get-url", "origin"])?;
        let valid_origin = [
            "git@github.com:deracs/reckon-native.git",
            "git@github.com:deracs/reckon-native",
            "https://github.com/deracs/reckon-native.git",
            "https://github.com/deracs/reckon-native",
            "ssh://git@github.com/deracs/reckon-native.git",
            "ssh://git@github.com/deracs/reckon-native",
        ]
        .contains(&origin.trim());
        #[cfg(test)]
        let valid_origin = self
            .origin_override
            .as_ref()
            .map_or(valid_origin, |expected| origin.trim() == expected);
        if !valid_origin {
            return Err(
                "Release origin must be the deracs/reckon-native GitHub repository.".into(),
            );
        }
        let repository: Value = serde_json::from_str(
            &self.capture("gh", &["repo", "view", "--json", "nameWithOwner"])?,
        )?;
        if repository["nameWithOwner"] != REPOSITORY {
            return Err("Release origin must resolve to deracs/reckon-native.".into());
        }
        self.capture("gh", &["auth", "status"])
            .map_err(|_| "Release requires gh authentication. Run gh auth login.")?;
        if !dry_run {
            self.capture("git", &["fetch", "origin", "main", "--tags"])?;
        }
        let remote = self.git(&["ls-remote", "origin", "refs/heads/main"])?;
        let sha = remote
            .split_whitespace()
            .next()
            .ok_or("Release origin has no main branch.")?;
        if !self
            .command("git", &["merge-base", "--is-ancestor", sha, "HEAD"])
            .status()?
            .success()
        {
            return Err(
                "Release main is behind or diverged from origin/main. Sync it before release."
                    .into(),
            );
        }
        Ok(())
    }

    fn read_plan(
        &self,
        selector: &str,
        notes: Option<&str>,
        resume: bool,
    ) -> ToolResult<ReleasePlan> {
        let plist = fs::read_to_string(self.root.join("Resources/Info.plist"))?;
        let old_version = plist_value(&plist, "CFBundleShortVersionString")?;
        let current = ReleaseVersion::parse(&old_version)?;
        let old_build = plist_value(&plist, "CFBundleVersion")?;
        let build = old_build.parse::<u64>()?;
        if build == 0 || old_build != build.to_string() {
            return Err("Release build must be a positive integer without leading zeros.".into());
        }
        let manifest = fs::read_to_string(self.root.join("Backend/Cargo.toml"))?;
        let lock = fs::read_to_string(self.root.join("Backend/Cargo.lock"))?;
        let version = if resume {
            ReleaseVersion::parse(selector)?
        } else {
            current.next(selector)?
        };
        if resume && version != current {
            return Err("Resume version must match this checkout's app version.".into());
        }
        let new_build = if resume {
            build
        } else {
            build.checked_add(1).ok_or("Release build overflow.")?
        };
        let new_manifest = replace_package_version(
            &manifest,
            "[package]",
            None,
            &old_version,
            &version.to_string(),
        )?;
        let new_lock = replace_package_version(
            &lock,
            "[[package]]",
            Some("reckon-backend"),
            &old_version,
            &version.to_string(),
        )?;
        let mut edits = vec![];
        if !resume {
            let notes_path =
                Path::new(notes.ok_or("Release requires --notes FILE. Use --help for examples.")?);
            let contents = fs::read_to_string(if notes_path.is_absolute() {
                notes_path.to_path_buf()
            } else {
                self.root.join(notes_path)
            })?;
            if contents.trim().is_empty() || contents.len() > 128 * 1024 {
                return Err("Release notes must contain 1–131072 bytes of UTF-8 text.".into());
            }
            let new_plist =
                replace_plist_value(&plist, "CFBundleShortVersionString", &version.to_string())?;
            let new_plist =
                replace_plist_value(&new_plist, "CFBundleVersion", &new_build.to_string())?;
            for (path, original, replacement) in [
                ("Resources/Info.plist", plist, new_plist),
                ("Backend/Cargo.toml", manifest, new_manifest),
                ("Backend/Cargo.lock", lock, new_lock),
                (NOTES, fs::read_to_string(self.root.join(NOTES))?, contents),
            ] {
                if original != replacement {
                    edits.push(ReleaseEdit {
                        path,
                        original,
                        replacement,
                    });
                }
            }
        }
        Ok(ReleasePlan {
            version,
            build: new_build,
            edits,
        })
    }

    fn release(&self, args: &[String]) -> ToolResult {
        if args == ["--help"] || args == ["-h"] {
            println!("{USAGE}");
            return Ok(());
        }
        let (selector, options) = args.split_first().ok_or(USAGE)?;
        let options = tool_options(options, &["notes"], &["dry-run", "resume"])?;
        let dry_run = options.contains_key("dry-run");
        let resume = options.contains_key("resume");
        if resume && options.contains_key("notes") {
            return Err("Resume uses the committed release notes; omit --notes.".into());
        }
        let plan = self.read_plan(selector, options.get("notes").map(String::as_str), resume)?;
        self.preflight(dry_run)?;
        let tag = plan.tag();
        let local_tag = self
            .command(
                "git",
                &[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("refs/tags/{tag}"),
                ],
            )
            .output()?
            .status
            .success();
        let remote_tag = self.git(&[
            "ls-remote",
            "origin",
            &format!("refs/tags/{tag}"),
            &format!("refs/tags/{tag}^{{}}"),
        ])?;
        if !resume && (local_tag || !remote_tag.trim().is_empty()) {
            return Err(
                format!("Release tag {tag} already exists. Use --resume to continue it.").into(),
            );
        }
        if resume && !local_tag {
            return Err(
                format!("Resume requires the existing local tag {tag}; fetch it first.").into(),
            );
        }
        println!(
            "[release] {tag}, build {}{}",
            plan.build,
            if dry_run { " (dry run)" } else { "" }
        );
        if dry_run {
            for edit in &plan.edits {
                println!("[release] Would update {}", edit.path);
            }
            if resume {
                println!(
                    "[release] Would resume the existing tag, retry failed CI jobs, verify publication, and sync main."
                );
            } else {
                println!(
                    "[release] Would run checks, commit, tag, push, wait for CI, verify publication, and sync main."
                );
            }
            return Ok(());
        }
        if !resume {
            self.prepare_commit(&plan)?;
        }
        let commit = self
            .git(&["rev-parse", &format!("{tag}^{{commit}}")])?
            .trim()
            .to_string();
        if !self
            .command("git", &["merge-base", "--is-ancestor", &commit, "HEAD"])
            .status()?
            .success()
        {
            return Err("Release tag is not part of this main history.".into());
        }
        let tagged_plist = self.git(&["show", &format!("{tag}:Resources/Info.plist")])?;
        if plist_value(&tagged_plist, "CFBundleShortVersionString")? != plan.version.to_string()
            || plist_value(&tagged_plist, "CFBundleVersion")? != plan.build.to_string()
        {
            return Err("Release tag contains a different app version or build.".into());
        }
        let result = self.publish(&plan, &commit, resume);
        result.map_err(|error| format!("{error}\nRelease tag {tag} is retained. Continue with: cargo reckon release {} --resume", plan.version).into())
    }

    fn prepare_commit(&self, plan: &ReleasePlan) -> ToolResult {
        let mut committed = false;
        let mut staged_by_release = false;
        let source_commit = self.git(&["rev-parse", "HEAD"])?;
        let result = (|| -> ToolResult {
            for edit in &plan.edits {
                write_release_file(&self.root.join(edit.path), &edit.replacement)?;
            }
            for (label, program, args) in [
                (
                    "Rust formatting and Clippy",
                    "cargo",
                    vec!["reckon", "check"],
                ),
                ("Build app", "./scripts/build-app.sh", vec![]),
                (
                    "Swift checks",
                    "swift",
                    vec!["run", "-Xswiftc", "-warnings-as-errors", "ReckonChecks"],
                ),
                (
                    "Image checks",
                    "swift",
                    vec![
                        "run",
                        "-Xswiftc",
                        "-warnings-as-errors",
                        "ReckonImageChecks",
                    ],
                ),
                ("Rust tests", "cargo", vec!["reckon", "test"]),
                (
                    "App signature",
                    "codesign",
                    vec!["--verify", "--deep", "--strict", "dist/Reckon.app"],
                ),
                (
                    "Source and bundle privacy",
                    "cargo",
                    vec!["reckon", "privacy", "--app", "dist/Reckon.app"],
                ),
            ] {
                self.visible(label, program, &args)?;
            }
            self.require_only_release_edits(plan)?;
            if self.git(&["rev-parse", "HEAD"])? != source_commit {
                return Err(
                    "Main changed during release checks. Review the new commits before retrying."
                        .into(),
                );
            }
            let mut args = vec!["add", "--"];
            args.extend(plan.edits.iter().map(|edit| edit.path));
            staged_by_release = true;
            self.capture("git", &args)?;
            self.visible(
                "Commit release",
                "git",
                &[
                    "commit",
                    "-m",
                    &format!("Prepare Reckon {} release", plan.tag()),
                ],
            )?;
            committed = true;
            self.visible(
                "Create annotated release tag",
                "git",
                &[
                    "-c",
                    "tag.gpgSign=false",
                    "tag",
                    "-a",
                    &plan.tag(),
                    "-m",
                    &format!("Reckon {}", plan.tag()),
                ],
            )?;
            Ok(())
        })();
        if result.is_err() && !committed {
            self.restore_edits(plan, staged_by_release)?;
        }
        if committed && result.is_err() {
            return Err(format!("Release commit is retained, but tagging failed. Resolve the Git error, create annotated tag {} on this commit, then use --resume.", plan.tag()).into());
        }
        result
    }

    fn require_only_release_edits(&self, plan: &ReleasePlan) -> ToolResult {
        let changed = self.git(&[
            "ls-files",
            "--modified",
            "--others",
            "--exclude-standard",
            "-z",
        ])?;
        let expected: BTreeSet<_> = plan.edits.iter().map(|e| e.path).collect();
        if changed
            .split('\0')
            .filter(|p| !p.is_empty())
            .any(|p| !expected.contains(p))
        {
            return Err(
                "Working tree changed during release checks. Unrelated edits remain untouched."
                    .into(),
            );
        }
        let staged = self.git(&["diff", "--cached", "--name-only", "-z"])?;
        if !staged.is_empty() {
            return Err(
                "The index changed during release checks; staged edits remain untouched.".into(),
            );
        }
        for edit in &plan.edits {
            if fs::read_to_string(self.root.join(edit.path))? != edit.replacement {
                return Err(
                    "Release files changed during checks; review them before retrying.".into(),
                );
            }
        }
        Ok(())
    }

    fn restore_edits(&self, plan: &ReleasePlan, staged_by_release: bool) -> ToolResult {
        for edit in &plan.edits {
            if staged_by_release
                && self.git(&["show", &format!(":{}", edit.path)])? == edit.replacement
            {
                self.capture("git", &["restore", "--staged", "--", edit.path])?;
            }
            let path = self.root.join(edit.path);
            if fs::read_to_string(&path)? == edit.replacement {
                write_release_file(&path, &edit.original)?;
            }
        }
        println!(
            "[release] Restored prepared files after failed checks; no release commit or tag was created."
        );
        Ok(())
    }

    fn publish(&self, plan: &ReleasePlan, commit: &str, resume: bool) -> ToolResult {
        let tag = plan.tag();
        let remote = self.git(&[
            "ls-remote",
            "origin",
            &format!("refs/tags/{tag}"),
            &format!("refs/tags/{tag}^{{}}"),
        ])?;
        if remote.trim().is_empty() {
            if self.git(&["rev-parse", "HEAD"])?.trim() != commit {
                return Err("Unpublished release tag must point to HEAD before pushing.".into());
            }
            self.visible(
                "Push main and tag atomically",
                "git",
                &[
                    "push",
                    "--atomic",
                    "origin",
                    "HEAD:refs/heads/main",
                    &format!("refs/tags/{tag}"),
                ],
            )?;
        } else if !remote
            .lines()
            .any(|line| line.split_whitespace().next() == Some(commit))
        {
            return Err(
                "Remote release tag points to a different commit. Tags are never overwritten."
                    .into(),
            );
        }
        let mut found = None;
        for attempt in 0..30 {
            let runs: Value = serde_json::from_str(&self.capture(
                "gh",
                &[
                    "run",
                    "list",
                    "--workflow",
                    WORKFLOW,
                    "--branch",
                    &tag,
                    "--commit",
                    commit,
                    "--event",
                    "push",
                    "--limit",
                    "20",
                    "--json",
                    "databaseId,headBranch,headSha,status,conclusion",
                ],
            )?)?;
            found = runs
                .as_array()
                .and_then(|runs| {
                    runs.iter()
                        .find(|run| run["headBranch"] == tag && run["headSha"] == commit)
                })
                .cloned();
            if found.is_some() {
                break;
            }
            if attempt < 29 {
                thread::sleep(Duration::from_secs(2));
            }
        }
        let run = found.ok_or("Release workflow did not appear within one minute.")?;
        let id = run["databaseId"]
            .as_u64()
            .ok_or("Release workflow ID missing.")?
            .to_string();
        println!("[release] https://github.com/{REPOSITORY}/actions/runs/{id}");
        if resume && run["status"] == "completed" && run["conclusion"] != "success" {
            self.visible(
                "Retry failed release jobs",
                "gh",
                &["run", "rerun", &id, "--failed"],
            )?;
        }
        self.visible(
            "Wait for release workflow",
            "gh",
            &["run", "watch", &id, "--interval", "15", "--exit-status"],
        )?;
        self.verify_publication(plan)?;
        if self.require_clean().is_ok() {
            self.visible(
                "Sync published update feeds",
                "git",
                &["pull", "--ff-only", "origin", "main"],
            )?;
        } else {
            println!(
                "[release] Published successfully. Local edits prevent syncing main; pull --ff-only after those edits are committed."
            );
        }
        println!("[release] Published https://github.com/{REPOSITORY}/releases/tag/{tag}");
        Ok(())
    }

    fn verify_publication(&self, plan: &ReleasePlan) -> ToolResult {
        let release = self.github(&format!("releases/tags/{}", plan.tag()))?;
        if release["tag_name"] != plan.tag()
            || release["draft"] != false
            || release["prerelease"] != false
        {
            return Err("Release is not published as a stable release.".into());
        }
        let assets = release["assets"]
            .as_array()
            .ok_or("Release assets missing.")?;
        if assets.len() != 4 {
            return Err("Release must contain two archives and two checksum files.".into());
        }
        for architecture in ["arm64", "x86_64"] {
            let archive = format!("Reckon-{}-macOS-{architecture}.zip", plan.version);
            let asset = assets
                .iter()
                .find(|a| a["name"] == archive && a["size"].as_u64().is_some_and(|s| s > 0))
                .ok_or("Published archive missing or empty.")?;
            if !assets.iter().any(|a| {
                a["name"] == format!("{archive}.sha256")
                    && a["size"].as_u64().is_some_and(|s| s > 0)
            }) {
                return Err("Published checksum missing or empty.".into());
            }
            let id = asset["id"].as_u64().ok_or("Release asset ID missing.")?;
            let response = self.github(&format!(
                "contents/updates/appcast-{architecture}.xml?ref=main"
            ))?;
            let encoded = response["content"]
                .as_str()
                .ok_or("Published feed missing.")?;
            let xml = String::from_utf8(
                STANDARD.decode(encoded.split_whitespace().collect::<String>())?,
            )?;
            for expected in [
                format!("<sparkle:version>{}</sparkle:version>", plan.build),
                format!(
                    "<sparkle:shortVersionString>{}</sparkle:shortVersionString>",
                    plan.version
                ),
                format!("https://api.github.com/repos/{REPOSITORY}/releases/assets/{id}"),
                "sparkle:edSignature=\"".to_string(),
            ] {
                if !xml.contains(&expected) {
                    return Err("Published update feed does not match the release.".into());
                }
            }
        }
        println!(
            "[release] Both release archives, checksum assets, and update feed versions are present."
        );
        Ok(())
    }
}

fn write_release_file(path: &Path, contents: &str) -> ToolResult {
    use std::io::Write;
    let parent = path
        .parent()
        .ok_or("Release file has no parent directory.")?;
    let permissions = fs::metadata(path)?.permissions();
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(contents.as_bytes())?;
    temporary.as_file().set_permissions(permissions)?;
    temporary.persist(path)?;
    Ok(())
}

fn plist_pattern(key: &str) -> ToolResult<Regex> {
    Ok(Regex::new(&format!(
        r"(<key>{}</key>\s*<string>)([^<]*)(</string>)",
        regex::escape(key)
    ))?)
}

fn plist_value(plist: &str, key: &str) -> ToolResult<String> {
    let pattern = plist_pattern(key)?;
    if pattern.captures_iter(plist).count() != 1 {
        return Err(format!("Release plist needs exactly one {key} field.").into());
    }
    Ok(pattern
        .captures(plist)
        .ok_or("Release plist field missing.")?[2]
        .to_string())
}

fn replace_plist_value(plist: &str, key: &str, value: &str) -> ToolResult<String> {
    plist_value(plist, key)?;
    Ok(plist_pattern(key)?
        .replace(plist, |c: &regex::Captures<'_>| {
            format!("{}{value}{}", &c[1], &c[3])
        })
        .into_owned())
}

fn replace_package_version(
    text: &str,
    header: &str,
    package: Option<&str>,
    old: &str,
    new: &str,
) -> ToolResult<String> {
    let name = Regex::new(r#"(?m)^name\s*=\s*"([^"]+)"\s*$"#)?;
    let version = Regex::new(r#"(?m)^(version\s*=\s*")([^"]+)("[^\r\n]*)$"#)?;
    let mut result = String::new();
    let mut matches = 0;
    let mut sections = text.split_inclusive('\n').peekable();
    while let Some(line) = sections.next() {
        result.push_str(line);
        if line.trim() != header {
            continue;
        }
        let mut body = String::new();
        while sections
            .peek()
            .is_some_and(|line| !line.trim_start().starts_with('['))
        {
            body.push_str(sections.next().expect("Peeked package body line exists"));
        }
        let correct_package =
            package.is_none_or(|expected| name.captures(&body).is_some_and(|c| &c[1] == expected));
        if correct_package {
            if version.captures_iter(&body).count() != 1
                || version.captures(&body).is_none_or(|c| &c[2] != old)
            {
                return Err("App, backend manifest, and backend lock versions must agree.".into());
            }
            body = version
                .replace(&body, |c: &regex::Captures<'_>| {
                    format!("{}{new}{}", &c[1], &c[3])
                })
                .into_owned();
            matches += 1;
        }
        result.push_str(&body);
    }
    if matches != 1 {
        return Err(
            "Release requires exactly one backend package version in each Cargo file.".into(),
        );
    }
    Ok(result)
}

#[cfg(test)]
#[path = "release_command_tests.rs"]
mod tests;
