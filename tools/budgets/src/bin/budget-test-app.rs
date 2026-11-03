//! A stand-in app for the budget harness: prints the first-frame marker, then idles.
//!
//! `BUDGET_TEST_APP_MODE` makes it misbehave for the harness tests:
//! `no-marker` never prints the marker, `exit-when-idle` exits 6 s after it.

use std::time::Duration;
use std::{env, thread};

fn main() {
    let mode = env::var("BUDGET_TEST_APP_MODE").unwrap_or_default();
    // Something resident to measure, touched so it counts towards RSS.
    let buffer = vec![1u8; 4 * 1024 * 1024];
    if mode != "no-marker" {
        println!("{}", budgets::FIRST_FRAME_MARKER);
    }
    if mode == "exit-when-idle" {
        thread::sleep(Duration::from_secs(6));
        return;
    }
    loop {
        thread::sleep(Duration::from_secs(3600));
        std::hint::black_box(&buffer);
    }
}
