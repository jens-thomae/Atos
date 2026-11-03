//! Launches an app and checks it against the §7 budgets. Linux only (reads `/proc`).
//!
//! Usage: `budgets <app> [--cpu-window <seconds>]`
//!
//! Prints a Markdown results table on stdout and exits with 1 if a budget is breached.

use budgets::{FIRST_FRAME_MARKER, limits, parse_cpu_ticks, parse_vm_rss_mb};
use std::io::{BufRead, BufReader};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};
use std::{env, fs, io, thread};

/// The app counts as idle from this long after its first frame.
const IDLE_AFTER: Duration = Duration::from_secs(5);
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
    let usage = "usage: budgets <app> [--cpu-window <seconds>]";
    let app = args.next().ok_or(usage)?;
    let cpu_window = match (args.next().as_deref(), args.next()) {
        (None, _) => 10,
        (Some("--cpu-window"), Some(s)) => s.parse().map_err(|_| usage)?,
        _ => return Err(usage.into()),
    };
    let cpu_window = Duration::from_secs(cpu_window);

    let start = Instant::now();
    let mut child = Command::new(&app)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot start {app}: {e}"))?;
    let result = measure(child.id(), child.stdout.take().unwrap(), start, cpu_window);
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
    pid: u32,
    stdout: impl io::Read + Send + 'static,
    start: Instant,
    cpu_window: Duration,
) -> Result<(f64, f64, f64), String> {
    let mut lines = BufReader::new(stdout).lines();
    loop {
        match lines.next() {
            Some(Ok(line)) if line.trim() == FIRST_FRAME_MARKER => break,
            Some(Ok(_)) => {}
            _ => return Err(format!("app exited before printing {FIRST_FRAME_MARKER}")),
        }
    }
    let cold_start = start.elapsed();
    // Keep reading so the app never blocks on a full pipe.
    thread::spawn(move || lines.for_each(drop));

    let proc_file = |name: &str| {
        fs::read_to_string(format!("/proc/{pid}/{name}"))
            .map_err(|e| format!("cannot read /proc/{pid}/{name} (Linux only): {e}"))
    };
    thread::sleep(IDLE_AFTER);
    let rss_mb = parse_vm_rss_mb(&proc_file("status")?).ok_or("no VmRSS in status")?;

    let ticks = || parse_cpu_ticks(&proc_file("stat")?).ok_or("cannot parse stat".to_string());
    let (t0, w0) = (ticks()?, Instant::now());
    thread::sleep(cpu_window);
    let (t1, window) = (ticks()?, w0.elapsed());
    let cpu_percent = (t1 - t0) as f64 / TICKS_PER_SEC / window.as_secs_f64() * 100.0;

    Ok((cold_start.as_secs_f64() * 1000.0, rss_mb, cpu_percent))
}
