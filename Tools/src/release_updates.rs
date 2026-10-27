use crate::{ToolResult, command_output, project_root};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};
use zeroize::Zeroizing;
const REPOSITORY: &str = "deracs/reckon-native";
const ACCOUNT: &str = "nz.reckon.native.update-signing";

/// Read a named property from an app plist without shell interpolation.
pub fn plist_field(plist: &Path, name: &str) -> ToolResult<String> {
    Ok(String::from_utf8(command_output(
        Command::new("/usr/libexec/PlistBuddy")
            .args(["-c", &format!("Print {name}")])
            .arg(plist),
        None,
    )?)?
    .trim()
    .to_string())
}
/// Hold a Sparkle signing source without exposing private key material through Debug or arguments.
pub struct SparkleSigner {
    seed: Option<Zeroizing<String>>,
    pub public_key: String,
}
impl SparkleSigner {
    pub fn from_seed(seed: String) -> ToolResult<Self> {
        let seed = Zeroizing::new(seed.trim().to_string());
        let decoded = Zeroizing::new(
            STANDARD
                .decode(seed.as_bytes())
                .map_err(|_| "Update signing key is invalid.")?,
        );
        let bytes: &[u8; 32] = decoded
            .as_slice()
            .try_into()
            .map_err(|_| "Update signing key must be a Sparkle Ed25519 seed.")?;
        let key = SigningKey::from_bytes(bytes);
        let public_key = STANDARD.encode(key.verifying_key().to_bytes());
        Ok(Self {
            seed: Some(seed),
            public_key,
        })
    }
    pub fn configured() -> ToolResult<Self> {
        if let Ok(seed) = env::var("SPARKLE_PRIVATE_KEY")
            && !seed.trim().is_empty()
        {
            return Self::from_seed(seed);
        }
        if env::var_os("CI").is_some() {
            return Err("Release signing requires the SPARKLE_PRIVATE_KEY Actions secret.".into());
        }
        let public_key = String::from_utf8(command_output(
            Command::new(project_root().join(".build/artifacts/sparkle/Sparkle/bin/generate_keys"))
                .args(["--account", ACCOUNT, "-p"]),
            None,
        )?)?
        .trim()
        .to_string();
        Ok(Self {
            seed: None,
            public_key,
        })
    }
    pub fn run(&self, args: &[&str]) -> ToolResult<String> {
        let mut command =
            Command::new(project_root().join(".build/artifacts/sparkle/Sparkle/bin/sign_update"));
        if self.seed.is_some() {
            command.args(["--ed-key-file", "-"]);
        } else {
            command.args(["--account", ACCOUNT]);
        }
        command.args(args);
        let output = command_output(&mut command, self.seed.as_ref().map(|seed| seed.as_bytes()))
            .map_err(|_| "Sparkle update signing or verification failed.")?;
        Ok(String::from_utf8(output)?.trim().to_string())
    }
}
/// Public archive metadata shared between build artifacts and the release feed publisher.
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateMetadata {
    pub archive: String,
    pub version: String,
    pub build: String,
    pub minimum_system_version: String,
    pub architecture: String,
    pub length: u64,
    pub signature: String,
    pub public_key: String,
}
/// Sign and verify a release ZIP with the app's existing trusted public key.
pub fn sign_release_archive(archive: &Path) -> ToolResult {
    let plist = project_root().join("dist/Reckon.app/Contents/Info.plist");
    let signer = SparkleSigner::configured()?;
    if signer.public_key != plist_field(&plist, "SUPublicEDKey")? {
        return Err("Update signing key does not match the app's public key.".into());
    }
    let path = archive.to_str().ok_or("Archive path is invalid.")?;
    let signature = signer.run(&["-p", path])?;
    if STANDARD.decode(&signature)?.len() != 64 {
        return Err("Invalid Sparkle archive signature.".into());
    }
    signer.run(&["--verify", path, &signature])?;
    let metadata = UpdateMetadata {
        archive: archive
            .file_name()
            .ok_or("Archive name missing.")?
            .to_string_lossy()
            .into_owned(),
        version: plist_field(&plist, "CFBundleShortVersionString")?,
        build: plist_field(&plist, "CFBundleVersion")?,
        minimum_system_version: plist_field(&plist, "LSMinimumSystemVersion")?,
        architecture: if cfg!(target_arch = "aarch64") {
            "arm64"
        } else {
            "x86_64"
        }
        .into(),
        length: fs::metadata(archive)?.len(),
        signature,
        public_key: signer.public_key,
    };
    fs::write(
        PathBuf::from(format!("{path}.update.json")),
        format!("{}\n", serde_json::to_string_pretty(&metadata)?),
    )?;
    println!("Signed and verified update archive: {}", metadata.archive);
    Ok(())
}
fn github(path: &str, method: &str, body: Option<Value>) -> ToolResult<Value> {
    let mut command = Command::new("gh");
    command.args([
        "api",
        &format!("repos/{REPOSITORY}/{path}"),
        "--method",
        method,
    ]);
    if body.is_some() {
        command.args(["--input", "-"]);
    }
    let bytes = body.map(|value| serde_json::to_vec(&value)).transpose()?;
    Ok(serde_json::from_slice(&command_output(
        &mut command,
        bytes.as_deref(),
    )?)?)
}
fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
/// Validate release metadata before any release or branch mutation.
pub fn validate_update_metadata(
    metadata: &UpdateMetadata,
    version: &str,
    architecture: &str,
    key: &str,
) -> ToolResult {
    if metadata.version != version
        || metadata.architecture != architecture
        || metadata.archive != format!("Reckon-{version}-macOS-{architecture}.zip")
        || metadata.public_key != key
        || metadata.build.starts_with('0')
        || !metadata.build.bytes().all(|byte| byte.is_ascii_digit())
        || metadata
            .build
            .parse::<u64>()
            .ok()
            .filter(|n| *n > 0)
            .is_none()
        || metadata.length == 0
        || STANDARD
            .decode(&metadata.signature)
            .map(|b| b.len())
            .unwrap_or(0)
            != 64
        || !regex::Regex::new(r"^[0-9]+(?:\.[0-9]+){1,2}$")?
            .is_match(&metadata.minimum_system_version)
    {
        return Err("Update feed metadata does not match this release.".into());
    }
    Ok(())
}
/// Generate an RSS feed whose enclosure references the verified GitHub release asset.
pub fn update_feed_xml(metadata: &UpdateMetadata, asset_id: u64) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\n<title>Reckon updates</title><link>https://github.com/{REPOSITORY}/releases</link><description>Signed Reckon updates for macOS.</description><language>en-NZ</language>\n<item><title>Reckon {version}</title>\n<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>\n<enclosure url=\"https://api.github.com/repos/{REPOSITORY}/releases/assets/{asset_id}\" length=\"{length}\" type=\"application/octet-stream\" sparkle:edSignature=\"{signature}\" />\n</item></channel></rss>\n",
        version = xml_escape(&metadata.version),
        build = xml_escape(&metadata.build),
        minimum = xml_escape(&metadata.minimum_system_version),
        length = metadata.length,
        signature = xml_escape(&metadata.signature)
    )
}
/// Verify both archives, sign both feeds, then optionally publish and commit them to main.
pub fn publish_update_feeds(tag: &str, publish: bool) -> ToolResult {
    if !regex::Regex::new(r"^v[0-9]+\.[0-9]+\.[0-9]+$")?.is_match(tag) {
        return Err("Update publication requires a stable version tag.".into());
    }
    let root = project_root();
    let signer = SparkleSigner::configured()?;
    if publish && signer.seed.is_none() {
        return Err("Publishing update feeds requires the Actions signing secret.".into());
    }
    let key = plist_field(&root.join("Resources/Info.plist"), "SUPublicEDKey")?;
    if signer.public_key != key {
        return Err("Update signing key does not match the app's public key.".into());
    }
    let release = if publish {
        Some(
            github("releases?per_page=100", "GET", None)?
                .as_array()
                .and_then(|items| items.iter().find(|item| item["tag_name"] == tag))
                .cloned()
                .ok_or("No draft or published release matches this tag.")?,
        )
    } else {
        None
    };
    let output = root.join(".build/update-feeds");
    fs::create_dir_all(&output)?;
    let mut entries = vec![];
    for architecture in ["arm64", "x86_64"] {
        let name = format!("Reckon-{}-macOS-{architecture}.zip", &tag[1..]);
        let archive = root.join("release").join(&name);
        let metadata: UpdateMetadata = serde_json::from_slice(&fs::read(
            root.join("release").join(format!("{name}.update.json")),
        )?)?;
        validate_update_metadata(&metadata, &tag[1..], architecture, &key)?;
        if fs::metadata(&archive)?.len() != metadata.length {
            return Err("Update archive length does not match metadata.".into());
        }
        signer.run(&[
            "--verify",
            archive.to_str().ok_or("Archive path invalid.")?,
            &metadata.signature,
        ])?;
        let asset_id = if let Some(release) = &release {
            let asset = release["assets"]
                .as_array()
                .and_then(|assets| {
                    assets.iter().find(|asset| {
                        asset["name"] == name && asset["size"].as_u64() == Some(metadata.length)
                    })
                })
                .ok_or("Update archive was not uploaded intact.")?;
            asset["id"].as_u64().ok_or("Release asset ID missing.")?
        } else if architecture == "arm64" {
            1001
        } else {
            1002
        };
        let filename = output.join(format!("appcast-{architecture}.xml"));
        fs::write(&filename, update_feed_xml(&metadata, asset_id))?;
        let path = filename.to_str().ok_or("Feed path invalid.")?;
        signer.run(&[path])?;
        signer.run(&["--verify", path])?;
        entries.push(json!({"path":format!("updates/appcast-{architecture}.xml"),"mode":"100644","type":"blob","content":fs::read_to_string(filename)?}));
    }
    if let Some(release) = release {
        let id = release["id"].as_u64().ok_or("Release ID missing.")?;
        github(
            &format!("releases/{id}"),
            "PATCH",
            Some(json!({"draft":false})),
        )?;
        let reference = github("git/ref/heads/main", "GET", None)?;
        let sha = reference["object"]["sha"]
            .as_str()
            .ok_or("Main ref missing.")?;
        let parent = github(&format!("git/commits/{sha}"), "GET", None)?;
        let tree = github(
            "git/trees",
            "POST",
            Some(json!({"base_tree":parent["tree"]["sha"],"tree":entries})),
        )?;
        let identity = json!({"name":"github-actions[bot]","email":"41898282+github-actions[bot]@users.noreply.github.com"});
        let commit = github(
            "git/commits",
            "POST",
            Some(
                json!({"message":format!("Publish signed update feeds for {tag}"),"tree":tree["sha"],"parents":[sha],"author":identity,"committer":identity}),
            ),
        )?;
        github(
            "git/refs/heads/main",
            "PATCH",
            Some(json!({"sha":commit["sha"],"force":false})),
        )?;
    }
    println!(
        "Signed and verified both update feeds{}.",
        if publish {
            " and published the release"
        } else {
            " (local preview only)"
        }
    );
    Ok(())
}
