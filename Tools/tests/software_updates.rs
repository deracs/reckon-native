use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use reckon_tools::release_updates::{
    SparkleSigner, UpdateMetadata, update_feed_xml, validate_update_metadata,
};
use std::fs;
use std::io::Read;
fn test_signer() -> SparkleSigner {
    let mut bytes = [0u8; 32];
    fs::File::open("/dev/urandom")
        .unwrap()
        .read_exact(&mut bytes)
        .unwrap();
    SparkleSigner::from_seed(STANDARD.encode(bytes)).unwrap()
}
#[test]
fn sparkle_rejects_tampered_archives_wrong_keys_and_tampered_feeds() {
    let folder = tempfile::tempdir().unwrap();
    let signer = test_signer();
    let other = test_signer();
    let archive = folder.path().join("fixture.zip");
    let path = archive.to_str().unwrap();
    fs::write(&archive, "synthetic signed update contents").unwrap();
    let signature = signer.run(&["-p", path]).unwrap();
    assert!(signer.run(&["--verify", path, &signature]).is_ok());
    assert!(other.run(&["--verify", path, &signature]).is_err());
    fs::write(&archive, "tampered signed update contents").unwrap();
    assert!(signer.run(&["--verify", path, &signature]).is_err());
    let feed = folder.path().join("appcast.xml");
    let path = feed.to_str().unwrap();
    fs::write(&feed,"<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Fixture</title></channel></rss>").unwrap();
    signer.run(&[path]).unwrap();
    signer.run(&["--verify", path]).unwrap();
    fs::write(
        &feed,
        fs::read_to_string(&feed)
            .unwrap()
            .replace("Fixture", "Tampered"),
    )
    .unwrap();
    assert!(signer.run(&["--verify", path]).is_err());
}
#[test]
fn release_metadata_rejects_mismatched_architectures_versions_names_keys_and_builds() {
    let signer = test_signer();
    let mut metadata = UpdateMetadata {
        archive: "Reckon-1.2.3-macOS-arm64.zip".into(),
        version: "1.2.3".into(),
        build: "19".into(),
        minimum_system_version: "15.0".into(),
        architecture: "arm64".into(),
        length: 123,
        signature: STANDARD.encode([1u8; 64]),
        public_key: signer.public_key.clone(),
    };
    let check = |metadata: &UpdateMetadata| {
        validate_update_metadata(metadata, "1.2.3", "arm64", &signer.public_key)
    };
    assert!(check(&metadata).is_ok());
    assert!(validate_update_metadata(&metadata, "1.2.4", "arm64", &signer.public_key).is_err());
    assert!(validate_update_metadata(&metadata, "1.2.3", "x86_64", &signer.public_key).is_err());
    assert!(validate_update_metadata(&metadata, "1.2.3", "arm64", "wrong").is_err());
    for build in ["0", "+19", "019", ""] {
        metadata.build = build.into();
        assert!(check(&metadata).is_err());
    }
    metadata.build = "19".into();
    metadata.signature = "invalid".into();
    assert!(check(&metadata).is_err());
    metadata.signature = STANDARD.encode([1u8; 64]);
    let feed = update_feed_xml(&metadata, 1234);
    assert!(feed.contains("releases/assets/1234"));
    assert!(feed.contains("<sparkle:version>19</sparkle:version>"));
}
