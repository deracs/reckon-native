use reckon_tools::{ToolResult, project_root, run_visible, tool_options};
use std::path::PathBuf;
use std::process::Command;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
async fn run() -> ToolResult {
    std::env::set_current_dir(project_root())?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (command, args) = args.split_first().ok_or("Usage: cargo reckon <check|fmt|test|build-backend|privacy|import-akahu|sign-update|publish-feeds|measure-backend|compare-live> [options]")?;
    match command.as_str() {
        "check" | "fmt" | "test" if args.is_empty() => {
            for manifest in ["Backend/Cargo.toml", "Tools/Cargo.toml"] {
                match command.as_str() {
                    "check" => {
                        run_visible(Command::new("cargo").args([
                            "fmt",
                            "--manifest-path",
                            manifest,
                            "--check",
                        ]))?;
                        run_visible(Command::new("cargo").args([
                            "clippy",
                            "--manifest-path",
                            manifest,
                            "--locked",
                            "--all-targets",
                            "--",
                            "-D",
                            "warnings",
                        ]))?;
                    }
                    "fmt" => run_visible(Command::new("cargo").args([
                        "fmt",
                        "--manifest-path",
                        manifest,
                    ]))?,
                    _ => run_visible(Command::new("cargo").args([
                        "test",
                        "--manifest-path",
                        manifest,
                        "--locked",
                    ]))?,
                }
            }
            Ok(())
        }
        "build-backend" if args.is_empty() => reckon_tools::build_backend::build_backend(),
        "privacy" => reckon_tools::release_privacy::check_release_privacy(args),
        "import-akahu" => reckon_tools::release_privacy::import_akahu_credentials(args),
        "sign-update" if args.len() == 1 => {
            reckon_tools::release_updates::sign_release_archive(&PathBuf::from(&args[0]))
        }
        "publish-feeds" => {
            let (tag, options) = args
                .split_first()
                .ok_or("Publish feeds requires a version tag.")?;
            let options = tool_options(options, &[], &["publish"])?;
            reckon_tools::release_updates::publish_update_feeds(
                tag,
                options.contains_key("publish"),
            )
        }
        "measure-backend" => reckon_tools::backend_benchmark::measure_backend(args).await,
        "compare-live" => reckon_tools::live_backend_comparison::compare_live_backends(args)
            .await
            .map_err(|_| "Live backend comparison failed. No bank records were saved.".into()),
        _ => Err("Unknown command or invalid arguments. Run cargo reckon for usage.".into()),
    }
}
