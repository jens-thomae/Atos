//! A stand-in app for the budget harness: prints the first-frame marker, then idles.

use std::thread;
use std::time::Duration;

fn main() {
    // Something resident to measure, touched so it counts towards RSS.
    let buffer = vec![1u8; 4 * 1024 * 1024];
    println!("{}", budgets::FIRST_FRAME_MARKER);
    loop {
        thread::sleep(Duration::from_secs(3600));
        std::hint::black_box(&buffer);
    }
}
