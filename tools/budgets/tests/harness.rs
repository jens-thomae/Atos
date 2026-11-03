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
