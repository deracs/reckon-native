use reckon_tools::{
    ToolResult,
    loopback_fixture::{FixtureResponse, LoopbackServer},
};
use serde::Deserialize;
use serde_json::json;
use std::{fs, io};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureConfiguration {
    mode: String,
    account_status: u16,
    hold_responses: bool,
}
#[tokio::main]
async fn main() {
    if run().await.is_err() {
        eprintln!("Synthetic backend fixture failed.");
        std::process::exit(1);
    }
}
async fn run() -> ToolResult {
    let executable = std::env::current_exe()?;
    let resources = executable
        .parent()
        .and_then(|p| p.parent())
        .ok_or("Fixture bundle missing.")?
        .join("Resources/Backend");
    let config: FixtureConfiguration =
        serde_json::from_slice(&fs::read(resources.join("fixture.json"))?)?;
    match config.mode.as_str() {
        "import" => {
            use std::io::Read;
            let mut input = Vec::new();
            io::stdin().read_to_end(&mut input)?;
            fs::write(resources.join("imported.json"), input)?;
            return Ok(());
        }
        "malformed" => println!("unexpected output"),
        "cancelled" => {
            let mut line = String::new();
            io::stdin().read_line(&mut line)?;
        }
        "unexpected-exit" => {
            println!("{}", json!({"event":"ready","port":12345}));
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            std::process::exit(1);
        }
        "dashboard" => {
            let mut line = String::new();
            io::stdin().read_line(&mut line)?;
            let server=LoopbackServer::start(move |request|{let hold=config.hold_responses;let status=config.account_status;Box::pin(async move {
                if hold{std::future::pending::<()>().await;}
                let mut response=FixtureResponse::json(if request.url.path()=="/forecast"{json!({"startDate":"2026-10-20","endDate":"2026-11-19","startingBalance":"0","endingBalance":"0","points":[],"events":[],"risks":[]})}else{json!([])});
                if request.url.path()=="/accounts" {response.status=status;}response
            })}).await?;
            fs::write(resources.join("child.pid"), std::process::id().to_string())?;
            let port = reqwest::Url::parse(&server.base_url)?
                .port()
                .ok_or("Fixture port missing.")?;
            println!("{}", json!({"event":"ready","port":port}));
            std::future::pending::<()>().await;
        }
        _ => return Err("Unknown backend fixture mode.".into()),
    }
    std::future::pending::<()>().await;
    Ok(())
}
