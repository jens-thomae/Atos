// SPDX-License-Identifier: MIT OR Apache-2.0
//! The shell's settings file (D-010: TOML, edited with `toml_edit` so a change to one value keeps
//! the user's comments and ordering). Today it holds the control centre's two stored switches:
//!
//! ```toml
//! [quick_settings]
//! dark_mode = false
//! do_not_disturb = false
//! ```
//!
//! The file is `$XDG_CONFIG_HOME/atos/shell.toml` (default `~/.config/atos/shell.toml`).

use std::path::{Path, PathBuf};

use toml_edit::{DocumentMut, value};

const TABLE: &str = "quick_settings";

pub fn path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("atos/shell.toml"))
}

/// A boolean setting; missing file, table or key (or a broken file) reads as `false`.
pub fn get_bool(file: &Path, key: &str) -> bool {
    std::fs::read_to_string(file)
        .ok()
        .and_then(|s| s.parse::<DocumentMut>().ok())
        .and_then(|d| d.get(TABLE)?.get(key)?.as_bool())
        .unwrap_or(false)
}

/// Sets a boolean, creating the file and table if needed. A file that does not parse is left
/// alone and reported: the user's hand edit must not be overwritten.
pub fn set_bool(file: &Path, key: &str, v: bool) -> Result<(), String> {
    let mut doc = match std::fs::read_to_string(file) {
        Ok(s) => s
            .parse::<DocumentMut>()
            .map_err(|e| format!("{}: {e}", file.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => DocumentMut::new(),
        Err(e) => return Err(format!("{}: {e}", file.display())),
    };
    if !doc.contains_table(TABLE) {
        doc[TABLE] = toml_edit::table();
    }
    doc[TABLE][key] = value(v);
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    // Write beside the file and rename: a crash never leaves half a config.
    let tmp = file.with_extension("toml.tmp");
    std::fs::write(&tmp, doc.to_string()).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, file).map_err(|e| format!("{}: {e}", file.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("atos-shell-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&d).ok();
        d
    }

    #[test]
    fn missing_file_reads_false_and_set_creates_it() {
        let f = dir("create").join("atos/shell.toml");
        assert!(!get_bool(&f, "dark_mode"));
        set_bool(&f, "dark_mode", true).unwrap();
        assert!(get_bool(&f, "dark_mode"));
        assert!(!get_bool(&f, "do_not_disturb"));
    }

    #[test]
    fn a_change_keeps_comments_and_other_keys() {
        let d = dir("keep");
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("shell.toml");
        std::fs::write(
            &f,
            "# mine\n[shell]\npreset = \"classic\" # keep\n\n[quick_settings]\ndark_mode = false\n",
        )
        .unwrap();
        set_bool(&f, "do_not_disturb", true).unwrap();
        let s = std::fs::read_to_string(&f).unwrap();
        assert!(
            s.contains("# mine") && s.contains("preset = \"classic\" # keep"),
            "{s}"
        );
        assert!(get_bool(&f, "do_not_disturb") && !get_bool(&f, "dark_mode"));
    }

    #[test]
    fn a_broken_file_is_not_overwritten() {
        let d = dir("broken");
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("shell.toml");
        std::fs::write(&f, "this is = = not toml").unwrap();
        assert!(set_bool(&f, "dark_mode", true).is_err());
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "this is = = not toml");
    }
}
