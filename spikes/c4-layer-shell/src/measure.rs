//! Timing hooks for #59, printed to stdout as `T59_*` lines (read by tools/t59/measure.sh).
//!
//! Popover fully visible = the compositor's presentation time of the popover's first frame
//! (wp_presentation, CLOCK_MONOTONIC) minus the time this process received the key or button
//! press that opened it (CLOCK_MONOTONIC, read on receipt). Not included: input device and kernel
//! latency before the compositor, and scanout after presentation.

use std::cell::Cell;
use std::io::Write;
use std::time::{Duration, Instant};

thread_local! {
    static INPUT: Cell<Option<(Instant, Duration)>> = const { Cell::new(None) };
    static REQUESTED: Cell<Option<Instant>> = const { Cell::new(None) };
    static CLOCK: Cell<u32> = const { Cell::new(u32::MAX) };
}

fn monotonic() -> Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: valid pointer to a timespec on the stack; CLOCK_MONOTONIC always exists on Linux.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

fn ms(d: Duration) -> String {
    format!("{:.1}", d.as_secs_f64() * 1000.0)
}

fn line(s: String) {
    println!("{s}");
    std::io::stdout().flush().ok();
}

pub fn first_frame() {
    line("BUDGET_FIRST_FRAME".into());
}

/// A key or button press arrived; `_wl_time` is the compositor's event time (ms), not used:
/// virtual keyboards (wtype) fill it in themselves.
pub fn input(_wl_time: u32) {
    INPUT.with(|i| i.set(Some((Instant::now(), monotonic()))));
}

pub fn popover_requested() {
    REQUESTED.with(|r| r.set(Some(Instant::now())));
}

pub fn popover_swapped() {
    let Some((t0, _)) = INPUT.with(Cell::get) else {
        return;
    };
    let req = REQUESTED
        .with(Cell::get)
        .map(|r| ms(r - t0))
        .unwrap_or_else(|| "?".into());
    line(format!(
        "T59_POPOVER_SWAPPED_MS {} requested_at {req}",
        ms(t0.elapsed())
    ));
}

pub fn popover_presented(at: Duration) {
    let Some((_, m0)) = INPUT.with(|i| i.take()) else {
        return;
    };
    let clock = CLOCK.with(Cell::get);
    // CLOCK_MONOTONIC is 1; any other clock cannot be compared with our input time.
    if clock != libc::CLOCK_MONOTONIC as u32 {
        line(format!("T59_POPOVER_VISIBLE_MS none clock {clock}"));
        return;
    }
    line(format!(
        "T59_POPOVER_VISIBLE_MS {}",
        ms(at.saturating_sub(m0))
    ));
}

pub fn popover_discarded() {
    INPUT.with(|i| i.take());
    line("T59_POPOVER_VISIBLE_MS discarded".into());
}

pub fn presentation_clock(clk: u32) {
    CLOCK.with(|c| c.set(clk));
}
