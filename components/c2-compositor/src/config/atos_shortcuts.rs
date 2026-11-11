// SPDX-License-Identifier: GPL-3.0-only
//! Atos shortcuts in the D-010 TOML config (#131), replacing the COSMIC RON shortcuts file for
//! them. File: `$XDG_CONFIG_HOME/atos/shortcuts.toml` (default `~/.config/atos/shortcuts.toml`).
//!
//! ```toml
//! [shortcuts]
//! launcher = ["Super", "Super+slash"]   # the default; "Super+space" etc. rebinds it
//! ```
//!
//! Read at start-up and again when the COSMIC shortcuts config changes (no file watch of its own;
//! add one when Settings edits it). An empty list gives the defaults: it cannot turn the launcher off.

use std::path::PathBuf;
use std::str::FromStr;

use cosmic_settings_config::shortcuts::{
    Action, Binding, Shortcuts, SystemActions, action::System,
};
use tracing::warn;

const DEFAULT_LAUNCHER: [&str; 2] = ["Super", "Super+slash"];
/// The command `System(Launcher)` runs (#64).
const LAUNCHER_COMMAND: &str = "atos-shell --launcher";
/// The commands the window switcher's actions run (#226): the shell draws it.
const SWITCHER_COMMANDS: [(System, &str); 2] = [
    (System::WindowSwitcher, "atos-shell --switcher next"),
    (System::WindowSwitcherPrevious, "atos-shell --switcher prev"),
];

pub fn path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("atos/shortcuts.toml"))
}

/// Launcher bindings from TOML text. A missing key gives the defaults; a broken file or an
/// unparsable binding is logged and ignored, so a typo never leaves the user without a launcher.
pub fn launcher_bindings(text: Option<&str>) -> Vec<Binding> {
    let keys: Option<Vec<String>> = text.and_then(|t| match t.parse::<toml::Table>() {
        Ok(doc) => doc.get("shortcuts")?.get("launcher")?.as_array().map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        }),
        Err(err) => {
            warn!(?err, "atos shortcuts.toml does not parse; using defaults");
            None
        }
    });
    let parse = |keys: &[String]| -> Vec<Binding> {
        keys.iter()
            .filter_map(|k| match Binding::from_str(k) {
                Ok(b) => Some(b),
                Err(err) => {
                    warn!(?err, key = %k, "ignoring unparsable launcher shortcut");
                    None
                }
            })
            .collect()
    };
    let bound = keys.as_deref().map(parse).unwrap_or_default();
    if bound.is_empty() {
        parse(&DEFAULT_LAUNCHER.map(String::from))
    } else {
        bound
    }
}

/// Makes `System(Launcher)` use `bindings` and its command, whatever the COSMIC config says.
pub fn apply(
    shortcuts: &mut Shortcuts,
    system_actions: &mut SystemActions,
    bindings: Vec<Binding>,
) {
    let action = Action::System(System::Launcher);
    shortcuts.0.retain(|_, a| *a != action);
    for b in bindings {
        shortcuts.0.insert(b, action.clone());
    }
    system_actions
        .entry(System::Launcher)
        .or_insert_with(|| LAUNCHER_COMMAND.to_string());
    for (system, command) in SWITCHER_COMMANDS {
        // A command the user set themselves stays.
        system_actions
            .entry(system)
            .or_insert_with(|| command.to_string());
    }
}

/// Reads the file (if any) and applies it.
pub fn load_and_apply(shortcuts: &mut Shortcuts, system_actions: &mut SystemActions) {
    let text = path().and_then(|p| std::fs::read_to_string(p).ok());
    apply(
        shortcuts,
        system_actions,
        launcher_bindings(text.as_deref()),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(keys: impl Iterator<Item = String>) -> Vec<String> {
        let mut k: Vec<_> = keys.collect();
        k.sort();
        k
    }

    fn want(keys: &[&str]) -> Vec<String> {
        sorted(
            keys.iter()
                .map(|k| Binding::from_str(k).unwrap().to_string()),
        )
    }

    fn launcher_keys(text: Option<&str>) -> Vec<String> {
        let mut s = Shortcuts::default();
        let mut a = SystemActions::new();
        apply(&mut s, &mut a, launcher_bindings(text));
        sorted(
            s.shortcuts(&Action::System(System::Launcher))
                .map(|b| b.to_string()),
        )
    }

    #[test]
    fn default_is_super_and_super_slash() {
        let default = want(&["Super", "Super+slash"]);
        assert_eq!(launcher_keys(None), default);
        assert_eq!(launcher_keys(Some("[shortcuts]\n")), default);
    }

    #[test]
    fn rebound_replaces_cosmic_bindings_and_sets_command() {
        let mut s = Shortcuts::default();
        s.0.insert(
            Binding::from_str("Super").unwrap(),
            Action::System(System::Launcher),
        );
        let mut a = SystemActions::new();
        apply(
            &mut s,
            &mut a,
            launcher_bindings(Some("[shortcuts]\nlauncher = [\"Super+space\"]\n")),
        );
        let keys = sorted(
            s.shortcuts(&Action::System(System::Launcher))
                .map(|b| b.to_string()),
        );
        assert_eq!(keys, want(&["Super+space"]));
        assert_eq!(a[&System::Launcher], LAUNCHER_COMMAND);
        assert_eq!(a[&System::WindowSwitcher], "atos-shell --switcher next");
        assert_eq!(
            a[&System::WindowSwitcherPrevious],
            "atos-shell --switcher prev"
        );
    }

    #[test]
    fn broken_file_or_binding_falls_back_to_default() {
        let default = want(&["Super", "Super+slash"]);
        assert_eq!(launcher_keys(Some("not = [toml")), default);
        assert_eq!(
            launcher_keys(Some("[shortcuts]\nlauncher = [\"Super+nosuchkey\"]\n")),
            default
        );
        assert_eq!(launcher_keys(Some("[shortcuts]\nlauncher = []\n")), default);
    }
}
