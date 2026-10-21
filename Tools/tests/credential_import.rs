use reckon_tools::release_privacy::import_akahu_credentials;
use serde_json::{Value, json};
use std::fs;
#[test]
fn importer_passes_only_literal_akahu_tokens_through_app_stdin() {
    let directory = tempfile::tempdir().unwrap();
    let bundle = directory.path().join("Fixture.app");
    let helpers = bundle.join("Contents/MacOS");
    let resources = bundle.join("Contents/Resources/Backend");
    fs::create_dir_all(&helpers).unwrap();
    fs::create_dir_all(&resources).unwrap();
    fs::copy(
        env!("CARGO_BIN_EXE_reckon-backend-fixture"),
        helpers.join("Reckon"),
    )
    .unwrap();
    fs::write(
        resources.join("fixture.json"),
        r#"{"mode":"import","accountStatus":200,"holdResponses":false}"#,
    )
    .unwrap();
    let env = directory.path().join("connection.env");
    fs::write(&env,"AKAHU_APP_TOKEN='$literal-app#token'\nAKAHU_USER_TOKEN=fixture-user\nUNRELATED_SECRET=must-not-be-forwarded\n").unwrap();
    import_akahu_credentials(&[
        env.to_string_lossy().into_owned(),
        bundle.to_string_lossy().into_owned(),
    ])
    .unwrap();
    let imported: Value =
        serde_json::from_slice(&fs::read(resources.join("imported.json")).unwrap()).unwrap();
    assert_eq!(
        imported,
        json!({"appToken":"$literal-app#token","userToken":"fixture-user"})
    );
}
#[test]
fn invalid_import_reports_no_token_value() {
    let directory = tempfile::tempdir().unwrap();
    let env = directory.path().join("invalid.env");
    fs::write(&env, "AKAHU_APP_TOKEN=fixture-private-value\n").unwrap();
    let error = import_akahu_credentials(&[env.to_string_lossy().into_owned()])
        .unwrap_err()
        .to_string();
    assert!(!error.contains("fixture-private-value"));
    assert!(error.starts_with("Could not import Akahu tokens."));
}
