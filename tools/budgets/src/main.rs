//! Launches an app and checks it against the §7 budgets. Linux only (reads `/proc`).
//!
//! Usage: `budgets <app> [--cpu-window <seconds>|full]` (`full` is the §7 window)
//!
//! Prints a Markdown results table on stdout and exits with 1 if a budget is breached,
//! 2 if it could not measure.

use budgets::{FIRST_FRAME_MARKER, limits, parse_cpu_ticks, parse_vm_rss_mb};
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use std::{env, fs, thread};

/// The app counts as idle from this long after its first frame.
const IDLE_AFTER: Duration = Duration::from_secs(5);
/// How long to wait for the first-frame marker before giving up (owner decision: 10× the budget).
const MARKER_TIMEOUT: Duration = Duration::from_millis(10 * limits::COLD_START_MS as u64);
// ponytail: USER_HZ is 100 on every architecture we target; read sysconf(_SC_CLK_TCK) if that changes.
const TICKS_PER_SEC: f64 = 100.0;

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("budgets: {e}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<bool, String> {
    let mut args = env::args().skip(1);
    let usage = "usage: budgets <app> [--cpu-window <seconds>|full]";
    let app = args.next().ok_or(usage)?;
    let cpu_window = match (args.next().as_deref(), args.next()) {
        (None, _) => 10,
        (Some("--cpu-window"), Some(s)) if s == "full" => limits::IDLE_CPU_WINDOW_S,
        (Some("--cpu-window"), Some(s)) => s.parse().map_err(|_| usage)?,
        _ => return Err(usage.into()),
    };
    let cpu_window = Duration::from_secs(cpu_window);

    let start = Instant::now();
    let mut child = Command::new(&app)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot start {app}: {e}"))?;
    let result = measure(&mut child, start, cpu_window);
    let _ = child.kill();
    let _ = child.wait();
    let (cold_start_ms, rss_mb, cpu_percent) = result?;

    let rows = [
        (
            "Cold start to first frame",
            format!("≤ {} ms", limits::COLD_START_MS),
            format!("{cold_start_ms:.0} ms"),
            cold_start_ms <= limits::COLD_START_MS,
        ),
        (
            "Idle RSS (5 s after first frame)",
            format!("≤ {} MB", limits::IDLE_RAM_MB),
            format!("{rss_mb:.1} MB"),
            rss_mb <= limits::IDLE_RAM_MB,
        ),
        (
            "Idle CPU",
            format!(
                "≤ {} % over {} s",
                limits::IDLE_CPU_PERCENT,
                cpu_window.as_secs()
            ),
            format!("{cpu_percent:.2} %"),
            cpu_percent <= limits::IDLE_CPU_PERCENT,
        ),
    ];
    println!("### Budgets: `{app}`\n");
    println!("| Metric | Budget | Measured | Result |\n| --- | --- | --- | --- |");
    for (metric, budget, measured, pass) in &rows {
        let result = if *pass { "✅ pass" } else { "❌ fail" };
        println!("| {metric} | {budget} | {measured} | {result} |");
    }
    Ok(rows.iter().all(|r| r.3))
}

/// Returns cold start in ms, idle RSS in MB and idle CPU in percent of one core.
fn measure(
    child: &mut Child,
    start: Instant,
    cpu_window: Duration,
) -> Result<(f64, f64, f64), String> {
    // Read stdout on a thread so a missing marker cannot block us, and keep
    // reading after it so the app never blocks on a full pipe.
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.trim() == FIRST_FRAME_MARKER {
                let _ = tx.send(Instant::now());
            }
        }
    });
    let cold_start = match rx.recv_timeout(MARKER_TIMEOUT) {
        Ok(at) => at - start,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            return Err(format!(
                "no {FIRST_FRAME_MARKER} within {} s",
                MARKER_TIMEOUT.as_secs_f64()
            ));
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            return Err(format!("app exited before printing {FIRST_FRAME_MARKER}"));
        }
    };

    let pid = child.id();
    let proc_file = |name: &str| {
        fs::read_to_string(format!("/proc/{pid}/{name}"))
            .map_err(|e| format!("cannot read /proc/{pid}/{name} (Linux only): {e}"))
    };
    // A dead app leaves a zombie whose /proc entries look idle, so check it still runs.
    let mut still_running = |when: &str| match child.try_wait() {
        Ok(None) => Ok(()),
        Ok(Some(status)) => Err(format!("app exited {when} ({status})")),
        Err(e) => Err(format!("cannot check the app: {e}")),
    };
    thread::sleep(IDLE_AFTER);
    still_running("before the idle RSS reading")?;
    let rss_mb = parse_vm_rss_mb(&proc_file("status")?).ok_or("no VmRSS in status")?;

    let ticks = || parse_cpu_ticks(&proc_file("stat")?).ok_or("cannot parse stat".to_string());
    let (t0, w0) = (ticks()?, Instant::now());
    thread::sleep(cpu_window);
    let (t1, window) = (ticks()?, w0.elapsed());
    still_running("during the idle CPU window")?;
    let cpu_percent = (t1 - t0) as f64 / TICKS_PER_SEC / window.as_secs_f64() * 100.0;

    Ok((cold_start.as_secs_f64() * 1000.0, rss_mb, cpu_percent))
}
