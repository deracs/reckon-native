use super::{ReleaseRunner, ReleaseVersion, plist_value, replace_package_version};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;

struct ReleaseFixture {
    _directory: tempfile::TempDir,
    root: PathBuf,
    origin: PathBuf,
}

impl ReleaseFixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("checkout");
        let origin = directory.path().join("origin.git");
        fs::create_dir_all(&root).unwrap();
        let fixture = Self {
            _directory: directory,
            root,
            origin,
        };
        fixture.git(&["init", "-b", "main"]);
        fixture.git(&["config", "user.name", "Release Fixture"]);
        fixture.git(&["config", "user.email", "fixture@users.noreply.github.com"]);
        fixture.git(&["config", "commit.gpgSign", "false"]);
        fixture.git(&["config", "tag.gpgSign", "true"]);
        fixture.git(&["config", "core.hooksPath", ".build/hooks"]);
        for folder in [
            "Resources",
            "Backend",
            ".github",
            "scripts",
            ".build/bin",
            ".build/hooks",
        ] {
            fs::create_dir_all(fixture.root.join(folder)).unwrap();
        }
        fixture.write(".gitignore", ".build/\n");
        fixture.write("Resources/Info.plist", "<plist><dict>\n<key>CFBundleShortVersionString</key><string>0.7.10</string>\n<key>CFBundleVersion</key><string>22</string>\n</dict></plist>\n");
        fixture.write("Backend/Cargo.toml", "[package]\nname = \"reckon-backend\"\nversion = \"0.7.10\"\n\n[dependencies]\nserde = \"1\"\n");
        fixture.write("Backend/Cargo.lock", "version = 4\n\n[[package]]\nname = \"dependency\"\nversion = \"0.7.10\"\n\n[[package]]\nname = \"reckon-backend\"\nversion = \"0.7.10\"\ndependencies = [\"dependency\"]\n");
        fixture.write(".github/release-notes.md", "Previous release notes.\n");
        fixture.write("other.txt", "Unrelated work.\n");
        fixture.executable(
            "scripts/build-app.sh",
            "#!/bin/sh\nprintf 'build-app\\n' >> .build/commands.log\n",
        );
        fixture.executable(
            ".build/bin/cargo",
            r#"#!/bin/sh
printf 'cargo %s\n' "$*" >> .build/commands.log
if [ "$*" = 'reckon test' ]; then
    if [ -f .build/fail-check ]; then exit 42; fi
    if [ -f .build/concurrent-edit ]; then printf 'Concurrent edit.\n' > other.txt; fi
fi
"#,
        );
        for program in ["swift", "codesign"] {
            fixture.executable(
                &format!(".build/bin/{program}"),
                &format!("#!/bin/sh\nprintf '{program} %s\\n' \"$*\" >> .build/commands.log\n"),
            );
        }
        fixture.executable(".build/bin/gh", r#"#!/bin/sh
printf 'gh %s\n' "$*" >> .build/commands.log
case "$1 $2" in
  'repo view') printf '{"nameWithOwner":"deracs/reckon-native"}\n' ;;
  'auth status') exit 0 ;;
  'run list')
    conclusion=success
    if [ -f .build/fail-ci ]; then conclusion=failure; fi
    commit=$(/usr/bin/git rev-parse 'v0.7.11^{commit}')
    printf '[{"databaseId":42,"headBranch":"v0.7.11","headSha":"%s","status":"completed","conclusion":"%s"}]\n' "$commit" "$conclusion"
    ;;
  'run watch') test ! -f .build/fail-ci ;;
  'run rerun') rm .build/fail-ci ;;
  'api repos/deracs/reckon-native/releases/tags/v0.7.11') cat .build/release.json ;;
  'api repos/deracs/reckon-native/contents/updates/appcast-arm64.xml?ref=main') cat .build/feed-arm64.json ;;
  'api repos/deracs/reckon-native/contents/updates/appcast-x86_64.xml?ref=main') cat .build/feed-x86_64.json ;;
  *) printf 'Unexpected fixture gh command: %s\n' "$*" >&2; exit 2 ;;
esac
"#);
        fixture.write(".build/notes.md", "A fictional new release.\n");
        fixture.prepare_publication();
        fixture.git(&["add", "."]);
        fixture.git(&["commit", "-m", "Fixture source"]);
        fixture.git(&["init", "--bare", fixture.origin.to_str().unwrap()]);
        fixture.git(&["remote", "add", "origin", fixture.origin.to_str().unwrap()]);
        fixture.git(&["push", "-u", "origin", "main"]);
        fixture
    }

    fn write(&self, path: &str, text: &str) {
        fs::write(self.root.join(path), text).unwrap();
    }

    fn executable(&self, path: &str, text: &str) {
        self.write(path, text);
        fs::set_permissions(self.root.join(path), fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn git(&self, args: &[&str]) -> String {
        let output = Command::new("/usr/bin/git")
            .current_dir(&self.root)
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Fixture git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    fn runner(&self) -> ReleaseRunner {
        let mut paths = vec![self.root.join(".build/bin")];
        paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
        ReleaseRunner {
            root: self.root.clone(),
            path_override: Some(std::env::join_paths(paths).unwrap()),
            origin_override: Some(self.origin.to_str().unwrap().to_string()),
        }
    }

    fn args(extra: &[&str]) -> Vec<String> {
        extra.iter().map(|s| s.to_string()).collect()
    }

    fn new_args() -> Vec<String> {
        Self::args(&["patch", "--notes", ".build/notes.md"])
    }

    fn calls(&self) -> String {
        fs::read_to_string(self.root.join(".build/commands.log")).unwrap_or_default()
    }

    fn prepare_publication(&self) {
        let mut assets = vec![];
        for (arch, id) in [("arm64", 1001), ("x86_64", 1002)] {
            let name = format!("Reckon-0.7.11-macOS-{arch}.zip");
            assets.push(json!({"id":id,"name":name,"size":500}));
            assets.push(json!({"id":id+100,"name":format!("{name}.sha256"),"size":96}));
            let xml = format!(
                "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:version>23</sparkle:version><sparkle:shortVersionString>0.7.11</sparkle:shortVersionString><enclosure url=\"https://api.github.com/repos/deracs/reckon-native/releases/assets/{id}\" sparkle:edSignature=\"fixture-signature\" /></item></channel></rss>"
            );
            self.write(
                &format!(".build/feed-{arch}.json"),
                &json!({"content":STANDARD.encode(xml)}).to_string(),
            );
        }
        self.write(
            ".build/release.json",
            &json!({"tag_name":"v0.7.11","draft":false,"prerelease":false,"assets":assets})
                .to_string(),
        );
    }
}

#[test]
fn release_versions_reject_ambiguous_or_injected_values_and_overflow() {
    let current = ReleaseVersion::parse("0.7.10").unwrap();
    for (selector, expected) in [
        ("patch", "0.7.11"),
        ("minor", "0.8.0"),
        ("major", "1.0.0"),
        ("v1.2.3", "1.2.3"),
    ] {
        assert_eq!(current.next(selector).unwrap().to_string(), expected);
    }
    for selector in [
        "0.7.10",
        "0.7.9",
        "00.8.0",
        "1.2",
        "1.2.3-beta",
        "1.2.3\n",
        "1.2.3;touch /tmp/invalid",
        "1.2.18446744073709551616",
    ] {
        assert!(
            current.next(selector).is_err(),
            "Invalid selector {selector:?}"
        );
    }
    assert!(
        ReleaseVersion::parse("1.2.18446744073709551615")
            .unwrap()
            .next("patch")
            .is_err()
    );
}

#[test]
fn release_updates_only_the_backend_lock_entry_and_rejects_version_drift() {
    let lock = "version = 4\n[[package]]\nname = \"other\"\nversion = \"0.7.10\"\n[[package]]\nname = \"reckon-backend\"\nversion = \"0.7.10\"\n";
    let result = replace_package_version(
        lock,
        "[[package]]",
        Some("reckon-backend"),
        "0.7.10",
        "0.7.11",
    )
    .unwrap();
    assert!(result.contains("name = \"other\"\nversion = \"0.7.10\""));
    assert!(result.contains("name = \"reckon-backend\"\nversion = \"0.7.11\""));
    assert!(
        replace_package_version(
            lock,
            "[[package]]",
            Some("reckon-backend"),
            "0.7.9",
            "0.7.11"
        )
        .is_err()
    );
}

#[test]
fn release_dry_run_leaves_files_commits_and_refs_unchanged() {
    let fixture = ReleaseFixture::new();
    let head = fixture.git(&["rev-parse", "HEAD"]);
    let mut args = ReleaseFixture::new_args();
    args.push("--dry-run".into());
    fixture.runner().release(&args).unwrap();
    assert_eq!(fixture.git(&["rev-parse", "HEAD"]), head);
    assert!(fixture.git(&["status", "--porcelain"]).is_empty());
    assert!(fixture.git(&["tag", "--list"]).is_empty());
    assert!(!fixture.calls().contains("cargo"));
    assert!(!fixture.calls().contains("run watch"));
}

#[test]
fn release_checks_commit_and_push_an_annotated_tag_then_confirm_publication() {
    let fixture = ReleaseFixture::new();
    fixture
        .runner()
        .release(&ReleaseFixture::new_args())
        .unwrap_or_else(|error| panic!("{error}\n{}", fixture.calls()));
    assert_eq!(fixture.git(&["cat-file", "-t", "v0.7.11"]).trim(), "tag");
    let commit = fixture.git(&["rev-parse", "HEAD"]);
    assert!(
        fixture
            .git(&["ls-remote", "origin", "refs/heads/main"])
            .contains(commit.trim())
    );
    assert!(
        fixture
            .git(&["ls-remote", "origin", "refs/tags/v0.7.11^{}"])
            .contains(commit.trim())
    );
    assert_eq!(
        fixture.git(&["show", "HEAD:.github/release-notes.md"]),
        "A fictional new release.\n"
    );
    let plist = fixture.git(&["show", "HEAD:Resources/Info.plist"]);
    assert_eq!(
        plist_value(&plist, "CFBundleShortVersionString").unwrap(),
        "0.7.11"
    );
    assert_eq!(plist_value(&plist, "CFBundleVersion").unwrap(), "23");
    assert_eq!(
        fs::metadata(fixture.root.join("Resources/Info.plist"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o644
    );
    let calls = fixture.calls();
    assert!(calls.find("cargo reckon test").unwrap() < calls.find("gh run watch").unwrap());
    assert!(calls.contains("cargo reckon privacy --app dist/Reckon.app"));
    assert!(fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn failed_checks_restore_version_notes_and_index_without_creating_a_tag() {
    let fixture = ReleaseFixture::new();
    fixture.write(".build/fail-check", "fail\n");
    let original = fixture.git(&["rev-parse", "HEAD"]);
    assert!(
        fixture
            .runner()
            .release(&ReleaseFixture::new_args())
            .is_err()
    );
    assert_eq!(fixture.git(&["rev-parse", "HEAD"]), original);
    assert!(fixture.git(&["status", "--porcelain"]).is_empty());
    assert!(fixture.git(&["tag", "--list"]).is_empty());
    assert!(!fixture.calls().contains("gh run watch"));
}

#[test]
fn release_preserves_unrelated_edits_made_during_checks() {
    let fixture = ReleaseFixture::new();
    fixture.write(".build/concurrent-edit", "edit\n");
    assert!(
        fixture
            .runner()
            .release(&ReleaseFixture::new_args())
            .is_err()
    );
    assert_eq!(
        fs::read_to_string(fixture.root.join("other.txt")).unwrap(),
        "Concurrent edit.\n"
    );
    assert_eq!(fixture.git(&["diff", "--name-only"]).trim(), "other.txt");
    assert!(fixture.git(&["tag", "--list"]).is_empty());
}

#[test]
fn release_resume_retries_ci_without_repeating_checks_or_bumping_again() {
    let fixture = ReleaseFixture::new();
    fixture.write(".build/fail-ci", "fail\n");
    let failure = fixture
        .runner()
        .release(&ReleaseFixture::new_args())
        .unwrap_err()
        .to_string();
    assert!(failure.contains("cargo reckon release 0.7.11 --resume"));
    let head = fixture.git(&["rev-parse", "HEAD"]);
    fixture
        .runner()
        .release(&ReleaseFixture::args(&["0.7.11", "--resume"]))
        .unwrap();
    assert_eq!(fixture.git(&["rev-parse", "HEAD"]), head);
    assert_eq!(fixture.calls().matches("cargo reckon test").count(), 1);
    assert!(fixture.calls().contains("gh run rerun 42 --failed"));
    assert!(fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn release_rejects_dirty_checkout_wrong_origin_and_existing_tags_before_edits() {
    let fixture = ReleaseFixture::new();
    fixture.write("other.txt", "Work in progress.\n");
    assert!(
        fixture
            .runner()
            .release(&ReleaseFixture::new_args())
            .unwrap_err()
            .to_string()
            .contains("clean working tree")
    );
    fixture.git(&["restore", "other.txt"]);
    fixture.git(&["remote", "set-url", "origin", "/not-the-release-repository"]);
    assert!(
        fixture
            .runner()
            .release(&ReleaseFixture::new_args())
            .unwrap_err()
            .to_string()
            .contains("Release origin")
    );
    fixture.git(&[
        "remote",
        "set-url",
        "origin",
        fixture.origin.to_str().unwrap(),
    ]);
    fixture.git(&["-c", "tag.gpgSign=false", "tag", "v0.7.11"]);
    assert!(
        fixture
            .runner()
            .release(&ReleaseFixture::new_args())
            .unwrap_err()
            .to_string()
            .contains("already exists")
    );
    assert!(fixture.git(&["status", "--porcelain"]).is_empty());
    assert!(!fixture.calls().contains("cargo"));
}

#[test]
fn release_does_not_report_success_for_a_stale_or_missing_update_feed() {
    let fixture = ReleaseFixture::new();
    fixture.write(
        ".build/feed-arm64.json",
        &json!({"content":STANDARD.encode("<rss>stale feed</rss>")}).to_string(),
    );
    let failure = fixture
        .runner()
        .release(&ReleaseFixture::new_args())
        .unwrap_err()
        .to_string();
    assert!(failure.contains("Published update feed does not match"));
    assert!(failure.contains("--resume"));
    assert_eq!(fixture.git(&["tag", "--list"]).trim(), "v0.7.11");
}
