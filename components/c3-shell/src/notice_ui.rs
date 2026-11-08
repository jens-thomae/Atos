// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shows the disk-not-sealed notice (#138) at login while `atos_shell::notice::STATE_FILE` exists.
//! "Dismiss" hides it for this shell process, so it is back at the next login.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;

use atos_shell::notice::{self, BODY, DOCS_URL, TITLE};
use atos_shell::{Notice, Palette};
use sctk::shell::wlr_layer::Anchor;
use slint::{ComponentHandle, Timer, TimerMode};

use crate::platform;

thread_local! {
    static SHOWN: RefCell<Option<Rc<Notice>>> = const { RefCell::new(None) };
    static POLL: Timer = Timer::default();
}

/// Looks now, then every 5 s for a minute: the seal unit may write the file after the session
/// has started. ponytail: no inotify; the unit finishes in seconds.
pub fn init(dark: bool) {
    if check(dark) {
        return;
    }
    let mut left = 12;
    POLL.with(|t| {
        t.start(TimerMode::Repeated, Duration::from_secs(5), move || {
            left -= 1;
            if check(dark) || left == 0 {
                POLL.with(|t| t.stop());
            }
        })
    });
}

fn check(dark: bool) -> bool {
    if !notice::unsealed(Path::new(notice::STATE_FILE)) {
        return false;
    }
    if let Err(e) = show(dark) {
        eprintln!("notice: {e}");
    }
    true
}

fn show(dark: bool) -> Result<(), Box<dyn std::error::Error>> {
    let ui = Rc::new(Notice::new()?);
    ui.global::<Palette>().set_dark(dark);
    ui.set_heading(TITLE.into());
    ui.set_body(BODY.into());
    ui.on_open_docs(|| {
        // The shell is the parent; a thread reaps the child so it does not stay a zombie.
        match std::process::Command::new("xdg-open").arg(DOCS_URL).spawn() {
            Ok(mut c) => {
                std::thread::spawn(move || c.wait().ok());
            }
            Err(e) => eprintln!("notice: xdg-open: {e}"),
        }
    });
    // Deferred: hiding the window inside its own event handler is not safe.
    ui.on_dismissed(|| {
        slint::invoke_from_event_loop(|| {
            if let Some(ui) = SHOWN.with(|s| s.borrow_mut().take()) {
                ui.hide().ok();
            }
        })
        .ok();
    });
    let gap = ui.get_edge_gap() as i32;
    let placement = platform::Placement {
        anchor: Anchor::TOP | Anchor::RIGHT,
        margin: [gap, gap, 0, 0],
        overlay: false,
    };
    platform::with_placement(placement, || ui.show())?;
    SHOWN.with(|s| *s.borrow_mut() = Some(ui));
    Ok(())
}
