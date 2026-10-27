use reckon_tools::command_output;
use std::fs;
use std::process::{Command, Stdio};

struct FixtureChildGuard(Option<String>);
impl Drop for FixtureChildGuard {
    fn drop(&mut self) {
        let Some(pid) = &self.0 else {
            return;
        };
        let _ = Command::new("/bin/kill")
            .args(["-KILL", pid])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

#[test]
fn failed_stdin_delivery_terminates_and_reaps_the_child() {
    let directory = tempfile::tempdir().expect("Create isolated subprocess fixture directory");
    let pid_file = directory.path().join("child.pid");
    let result = command_output(
        Command::new("/bin/sh")
            .args([
                "-c",
                "printf '%s' \"$$\" > \"$1\"; exec 0<&-; exec /bin/sleep 30",
                "reckon-stdin-fixture",
            ])
            .arg(&pid_file),
        Some(&vec![0u8; 1024 * 1024]),
    );
    let pid = fs::read_to_string(pid_file).expect("Child records its PID before closing stdin");
    let mut cleanup = FixtureChildGuard(Some(pid.clone()));
    assert!(result.is_err(), "A closed stdin pipe must fail delivery");
    let alive = Command::new("/bin/kill")
        .args(["-0", &pid])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("Inspect fixture process liveness")
        .success();
    if !alive {
        cleanup.0 = None;
    }
    assert!(
        !alive,
        "Failed stdin delivery must terminate and reap the owned child before returning"
    );
}
