//! The X display for started apps. atos-session starts the shell from greetd, before Xwayland
//! exists, so the shell has `WAYLAND_DISPLAY` but never `DISPLAY`. atos-comp writes the X display
//! into the systemd user environment once, when it is ready (#230). It does not update it if Xwayland
//! restarts with another number (C2 card), so the value is read at each launch, not once at start.

use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// The `DISPLAY` value in `systemctl --user show-environment` output, if it is non-empty.
fn display_in(env: &str) -> Option<&str> {
    env.lines()
        .find_map(|l| l.strip_prefix("DISPLAY="))
        .filter(|d| !d.is_empty())
}

/// Gives `cmd` `display`, unless the shell was started with one or there is none.
fn apply(cmd: &mut Command, display: Option<&str>) {
    if std::env::var_os("DISPLAY").is_some_and(|d| !d.is_empty()) {
        return;
    }
    if let Some(d) = display {
        cmd.env("DISPLAY", d);
    }
}

/// Asks the user manager, for at most 2 s; `None` on any failure.
fn systemd_display() -> Option<String> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let out = Command::new("systemctl")
            .args(["--user", "show-environment"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| display_in(&s).map(String::from));
        tx.send(out).ok();
    });
    rx.recv_timeout(Duration::from_secs(2)).ok().flatten()
}

fn start(mut cmd: Command, lookup: impl FnOnce() -> Option<String>) -> std::io::Result<Child> {
    apply(&mut cmd, lookup().as_deref());
    cmd.spawn()
}

/// Starts `cmd` with the current X display and reaps it, all off the calling (event loop) thread.
/// A failed lookup starts the app without `DISPLAY`; `what` names the app in the error message.
pub fn spawn_detached(cmd: Command, what: String) {
    std::thread::spawn(move || match start(cmd, systemd_display) {
        Ok(mut child) => drop(child.wait()),
        Err(e) => eprintln!("{what}: {e}"),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of(cmd: &Command, key: &str) -> Option<String> {
        cmd.get_envs()
            .find(|(k, _)| *k == key)
            .and_then(|(_, v)| v.map(|v| v.to_string_lossy().into_owned()))
    }

    #[test]
    fn finds_whatever_display_number_xwayland_got() {
        assert_eq!(
            display_in("LANG=C\nDISPLAY=:0\nWAYLAND_DISPLAY=wayland-1\n"),
            Some(":0")
        );
        assert_eq!(display_in("DISPLAY=:7\n"), Some(":7"));
        assert_eq!(display_in("WAYLAND_DISPLAY=wayland-1\nDISPLAY=\n"), None);
    }

    #[test]
    fn command_carries_display_when_known_and_is_untouched_when_not() {
        if std::env::var_os("DISPLAY").is_some_and(|d| !d.is_empty()) {
            return; // an inherited display wins; the case is not testable here
        }
        let mut c = Command::new("true");
        apply(&mut c, Some(":7"));
        assert_eq!(env_of(&c, "DISPLAY").as_deref(), Some(":7"));
        let mut c = Command::new("true");
        apply(&mut c, None);
        assert_eq!(c.get_envs().count(), 0);
    }

    #[test]
    fn started_app_sees_the_looked_up_display() {
        if std::env::var_os("DISPLAY").is_some_and(|d| !d.is_empty()) {
            return;
        }
        let mut c = Command::new("sh");
        c.args(["-c", "test \"$DISPLAY\" = :7"]);
        assert!(
            start(c, || Some(":7".into()))
                .unwrap()
                .wait()
                .unwrap()
                .success()
        );
    }

    #[test]
    fn failed_lookup_still_starts_the_app() {
        let c = Command::new("true");
        assert!(start(c, || None).unwrap().wait().unwrap().success());
    }
}
