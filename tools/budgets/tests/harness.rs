//! Runs the `budgets` binary on misbehaving test apps.

use std::process::{Command, Output};
use std::time::{Duration, Instant};

fn run_harness(mode: &str, cpu_window: &str) -> (Output, Duration) {
    let start = Instant::now();
    let out = Command::new(env!("CARGO_BIN_EXE_budgets"))
        .args([
            env!("CARGO_BIN_EXE_budget-test-app"),
            "--cpu-window",
            cpu_window,
        ])
        .env("BUDGET_TEST_APP_MODE", mode)
        .output()
        .unwrap();
    (out, start.elapsed())
}

#[test]
fn missing_marker_fails_fast() {
    let (out, took) = run_harness("no-marker", "1");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("no BUDGET_FIRST_FRAME within 3 s"),
        "{stderr}"
    );
    assert!(took < Duration::from_secs(5), "took {took:?}");
}

// Needs /proc; elsewhere the harness fails earlier with a different message.
#[cfg(target_os = "linux")]
#[test]
fn app_exit_during_cpu_window_fails() {
    // The app exits 6 s after its first frame: after the 5 s RSS reading, inside the 2 s window.
    let (out, _) = run_harness("exit-when-idle", "2");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("app exited during the idle CPU window"),
        "{stderr}"
    );
}

#[cfg(target_os = "linux")]
#[test]
fn writes_json_that_compare_reads() {
    let json = std::env::temp_dir().join(format!("budgets-{}.json", std::process::id()));
    let json = json.to_str().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_budgets"))
        .args([
            env!("CARGO_BIN_EXE_budget-test-app"),
            "--cpu-window",
            "1",
            "--json",
            json,
        ])
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    let written = std::fs::read_to_string(json).unwrap();
    assert!(written.contains("\"cpu_window_s\": 1"), "{written}");
    // A run compared with itself never regresses.
    let out = Command::new(env!("CARGO_BIN_EXE_budgets"))
        .args(["compare", json, json, "5"])
        .output()
        .unwrap();
    let _ = std::fs::remove_file(json);
    assert!(out.status.success(), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("| Idle CPU |"));
}
