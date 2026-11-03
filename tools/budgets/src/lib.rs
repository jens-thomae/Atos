//! Quality budget checks (spec §7). See `docs/budgets.md`.

/// Printed by an app on stdout when its first usable frame is presented.
pub const FIRST_FRAME_MARKER: &str = "BUDGET_FIRST_FRAME";

/// Budget limits. Mirrors the table in `docs/spec.md` §7 (Quality budgets);
/// change both together. Only budgets the harness checks are listed.
pub mod limits {
    /// Apps: cold start of a native app to first usable frame.
    pub const COLD_START_MS: f64 = 300.0;
    /// System: idle desktop RAM after login. Phase 0 applies it to one app.
    pub const IDLE_RAM_MB: f64 = 800.0;
    /// System: idle desktop CPU, in percent of one core, averaged over 5 minutes.
    pub const IDLE_CPU_PERCENT: f64 = 1.0;
    /// System: the 5-minute window for `IDLE_CPU_PERCENT`, in seconds.
    pub const IDLE_CPU_WINDOW_S: u64 = 300;
    /// Accessibility: text contrast for body text.
    pub const CONTRAST_BODY: f64 = 4.5;
    /// Accessibility: text contrast for large text.
    pub const CONTRAST_LARGE: f64 = 3.0;
}

/// WCAG 2.x contrast ratio between two sRGB colours, from 1.0 to 21.0.
pub fn contrast_ratio(a: [u8; 3], b: [u8; 3]) -> f64 {
    let (la, lb) = (relative_luminance(a), relative_luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

/// Whether a contrast ratio meets the §7 budget for body or large text.
pub fn contrast_passes(ratio: f64, large_text: bool) -> bool {
    ratio
        >= if large_text {
            limits::CONTRAST_LARGE
        } else {
            limits::CONTRAST_BODY
        }
}

fn relative_luminance([r, g, b]: [u8; 3]) -> f64 {
    let lin = |c: u8| {
        let c = f64::from(c) / 255.0;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

/// Resident set size in decimal MB (10^6 bytes) from the text of `/proc/<pid>/status`.
pub fn parse_vm_rss_mb(status: &str) -> Option<f64> {
    let kb: f64 = status
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))?
        .trim()
        .strip_suffix("kB")?
        .trim()
        .parse()
        .ok()?;
    // The kernel's "kB" is KiB (1024 bytes).
    Some(kb * 1024.0 / 1_000_000.0)
}

/// User plus system CPU time in clock ticks from the text of `/proc/<pid>/stat`.
pub fn parse_cpu_ticks(stat: &str) -> Option<u64> {
    // The command name (field 2) may contain spaces, so count from its closing ')'.
    // After it come field 3 (state) onwards; utime and stime are fields 14 and 15.
    let mut fields = stat.rsplit_once(')')?.1.split_whitespace().skip(11);
    let utime: u64 = fields.next()?.parse().ok()?;
    let stime: u64 = fields.next()?.parse().ok()?;
    Some(utime + stime)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round2(x: f64) -> f64 {
        (x * 100.0).round() / 100.0
    }

    #[test]
    fn contrast_known_pairs() {
        assert_eq!(round2(contrast_ratio([0x77; 3], [0xff; 3])), 4.48);
        assert_eq!(round2(contrast_ratio([0x76; 3], [0xff; 3])), 4.54);
        assert_eq!(contrast_ratio([0; 3], [0xff; 3]), 21.0);
        assert_eq!(contrast_ratio([0x12, 0x34, 0x56], [0x12, 0x34, 0x56]), 1.0);
        // Order does not matter.
        assert_eq!(
            contrast_ratio([0xff; 3], [0x77; 3]),
            contrast_ratio([0x77; 3], [0xff; 3])
        );
    }

    #[test]
    fn contrast_thresholds() {
        let grey_on_white = contrast_ratio([0x77; 3], [0xff; 3]);
        assert!(!contrast_passes(grey_on_white, false));
        assert!(contrast_passes(grey_on_white, true));
        assert!(contrast_passes(contrast_ratio([0x76; 3], [0xff; 3]), false));
        // #949494 on white is about 3.03:1, just enough for large text.
        let just_large = contrast_ratio([0x94; 3], [0xff; 3]);
        assert!(contrast_passes(just_large, true));
        assert!(!contrast_passes(just_large, false));
        // #959595 on white is about 2.9:1, too low even for large text.
        assert!(!contrast_passes(contrast_ratio([0x95; 3], [0xff; 3]), true));
    }

    #[test]
    fn parses_vm_rss() {
        let status = "Name:\tapp\nVmPeak:\t  9000 kB\nVmRSS:\t    2048 kB\nThreads:\t1\n";
        assert_eq!(parse_vm_rss_mb(status), Some(2.097152));
        assert_eq!(parse_vm_rss_mb("Name:\tapp\n"), None);
    }

    #[test]
    fn parses_cpu_ticks() {
        // A command name with spaces and a ')' inside.
        let stat =
            "1234 (my (app) x) S 1 1234 1234 0 -1 4194304 100 0 0 0 7 5 0 0 20 0 1 0 100 1000 200";
        assert_eq!(parse_cpu_ticks(stat), Some(12));
        assert_eq!(parse_cpu_ticks("1234 (app) S 1"), None);
    }
}
