//! The X display for started apps. atos-session starts the shell from greetd, before Xwayland
//! exists, so the shell has `WAYLAND_DISPLAY` but never `DISPLAY`. atos-comp announces the X display
//! in the systemd user environment once Xwayland is up (and again after a restart with another
//! number), so it is read at each launch instead of once at start (#230).

use std::process::Command;

/// The `DISPLAY` value in `systemctl --user show-environment` output, if it is non-empty.
fn display_in(env: &str) -> Option<&str> {
    env.lines()
        .find_map(|l| l.strip_prefix("DISPLAY="))
        .filter(|d| !d.is_empty())
}

/// Gives `cmd` the current X display, unless the shell was started with one.
pub fn set_display(cmd: &mut Command) {
    if std::env::var_os("DISPLAY").is_some_and(|d| !d.is_empty()) {
        return;
    }
    let out = Command::new("systemctl")
        .args(["--user", "show-environment"])
        .output();
    if let Some(d) = out
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .as_deref()
        .and_then(display_in)
    {
        cmd.env("DISPLAY", d);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_whatever_display_number_xwayland_got() {
        assert_eq!(
            display_in("LANG=C\nDISPLAY=:0\nWAYLAND_DISPLAY=wayland-1\n"),
            Some(":0")
        );
        assert_eq!(display_in("DISPLAY=:7\n"), Some(":7"));
    }

    #[test]
    fn ignores_missing_empty_and_wayland_only() {
        assert_eq!(display_in("WAYLAND_DISPLAY=wayland-1\n"), None);
        assert_eq!(display_in("DISPLAY=\n"), None);
    }
}
