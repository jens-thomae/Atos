// SPDX-License-Identifier: MIT OR Apache-2.0
//! Finds an app's icon from its Wayland app ID: the `Icon=` key of `<app_id>.desktop`
//! (freedesktop Desktop Entry spec), looked up in the hicolor theme and `pixmaps` of the XDG data
//! directories (Icon Theme spec).
//!
//! ponytail: hicolor only, a fixed list of sizes and no index.theme parsing. A user icon theme
//! comes with theming (Phase 4); add the theme lookup then.

use std::path::{Path, PathBuf};

const CANDIDATES: &[&str] = &[
    "icons/hicolor/scalable/apps/{}.svg",
    "icons/hicolor/256x256/apps/{}.png",
    "icons/hicolor/128x128/apps/{}.png",
    "icons/hicolor/96x96/apps/{}.png",
    "icons/hicolor/64x64/apps/{}.png",
    "icons/hicolor/48x48/apps/{}.png",
    "pixmaps/{}.svg",
    "pixmaps/{}.png",
];

/// The app's icon, or an empty image.
pub fn load(app_id: &str) -> slint::Image {
    icon_path(app_id)
        .and_then(|p| slint::Image::load_from_path(&p).ok())
        .unwrap_or_default()
}

pub fn icon_path(app_id: &str) -> Option<PathBuf> {
    icon_path_in(&data_dirs(), app_id)
}

pub fn icon_path_in(dirs: &[PathBuf], app_id: &str) -> Option<PathBuf> {
    // An app ID is a reverse-DNS name; refuse anything that could leave the data directories.
    if app_id.is_empty() || app_id.contains('/') || app_id.starts_with('.') {
        return None;
    }
    let icon = dirs
        .iter()
        .find_map(|d| desktop_icon(&d.join("applications").join(format!("{app_id}.desktop"))))
        .unwrap_or_else(|| app_id.to_owned());
    if Path::new(&icon).is_absolute() {
        return Some(PathBuf::from(icon)).filter(|p| p.is_file());
    }
    if icon.contains('/') {
        return None;
    }
    dirs.iter()
        .flat_map(|d| CANDIDATES.iter().map(|c| d.join(c.replace("{}", &icon))))
        .find(|p| p.is_file())
}

/// `Icon=` in the `[Desktop Entry]` group.
fn desktop_icon(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry && let Some(v) = line.strip_prefix("Icon=") {
            return Some(v.trim().to_owned()).filter(|v| !v.is_empty());
        }
    }
    None
}

/// `$XDG_DATA_HOME` (default `~/.local/share`), then `$XDG_DATA_DIRS` (default
/// `/usr/local/share:/usr/share`).
fn data_dirs() -> Vec<PathBuf> {
    let var = |k| std::env::var_os(k).filter(|v| !v.is_empty());
    let home = var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| var("HOME").map(|h| PathBuf::from(h).join(".local/share")));
    let rest = var("XDG_DATA_DIRS").unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    home.into_iter()
        .chain(std::env::split_paths(&rest))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icon_from_desktop_entry_then_hicolor() {
        let root = std::env::temp_dir().join(format!("atos-shell-icons-{}", std::process::id()));
        let (a, b) = (root.join("a"), root.join("b"));
        std::fs::create_dir_all(a.join("applications")).unwrap();
        std::fs::create_dir_all(b.join("icons/hicolor/48x48/apps")).unwrap();
        std::fs::create_dir_all(b.join("icons/hicolor/scalable/apps")).unwrap();
        std::fs::write(
            a.join("applications/org.example.App.desktop"),
            "[Desktop Action new]\nIcon=wrong\n[Desktop Entry]\nName=App\nIcon=example-app\n",
        )
        .unwrap();
        std::fs::write(b.join("icons/hicolor/48x48/apps/example-app.png"), "").unwrap();
        std::fs::write(b.join("icons/hicolor/scalable/apps/other.svg"), "").unwrap();
        let dirs = [a, b.clone()];

        // Desktop entry gives the icon name; scalable is preferred, so 48x48 is the only match.
        assert_eq!(
            icon_path_in(&dirs, "org.example.App"),
            Some(b.join("icons/hicolor/48x48/apps/example-app.png"))
        );
        // No desktop entry: the app ID is the icon name.
        assert_eq!(
            icon_path_in(&dirs, "other"),
            Some(b.join("icons/hicolor/scalable/apps/other.svg"))
        );
        assert_eq!(icon_path_in(&dirs, "missing"), None);
        assert_eq!(icon_path_in(&dirs, "../a/applications/x"), None);
        std::fs::remove_dir_all(root).unwrap();
    }
}
