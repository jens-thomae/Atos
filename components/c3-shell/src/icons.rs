// SPDX-License-Identifier: MIT OR Apache-2.0
//! Finds an app's icon from its Wayland app ID: the `Icon=` key of `<app_id>.desktop`
//! (freedesktop Desktop Entry spec), looked up in the hicolor theme and `pixmaps` of the XDG data
//! directories (Icon Theme spec). The launcher (#64) looks up `Icon=` names directly (`load_named`).
//!
//! ponytail: hicolor only, a fixed list of sizes and no index.theme parsing. A user icon theme
//! comes with theming (Phase 4); add the theme lookup then.

use std::path::{Path, PathBuf};

// (path, pixel size; 0 = scalable). Smallest PNG first that is still at least the size the icon is
// drawn at in physical pixels: decoding a list of 256 px icons for the launcher costs far more than
// it shows, and a 48 px icon on a 2x output is blurry.
const CANDIDATES: &[(&str, u32)] = &[
    ("icons/hicolor/scalable/apps/{}.svg", 0),
    ("icons/hicolor/48x48/apps/{}.png", 48),
    ("icons/hicolor/64x64/apps/{}.png", 64),
    ("icons/hicolor/96x96/apps/{}.png", 96),
    ("icons/hicolor/128x128/apps/{}.png", 128),
    ("icons/hicolor/256x256/apps/{}.png", 256),
    ("pixmaps/{}.svg", 0),
    ("pixmaps/{}.png", 0),
];

/// The app's icon, or an empty image.
/// `px` is the physical size it is drawn at (logical size times the output's scale).
pub fn load(app_id: &str, px: u32) -> slint::Image {
    icon_path(app_id, px)
        .and_then(|p| slint::Image::load_from_path(&p).ok())
        .unwrap_or_default()
}

pub fn icon_path(app_id: &str, px: u32) -> Option<PathBuf> {
    icon_path_in(&data_dirs(), app_id, px)
}

pub fn icon_path_in(dirs: &[PathBuf], app_id: &str, px: u32) -> Option<PathBuf> {
    // An app ID is a reverse-DNS name; refuse anything that could leave the data directories.
    if app_id.is_empty() || app_id.contains('/') || app_id.starts_with('.') {
        return None;
    }
    let icon = dirs
        .iter()
        .find_map(|d| desktop_icon(&d.join("applications").join(format!("{app_id}.desktop"))))
        .unwrap_or_else(|| app_id.to_owned());
    named_icon_in(dirs, &icon, px)
}

/// An `Icon=` value (a name or an absolute path) as an image, or an empty image.
pub fn load_named(icon: &str, px: u32) -> slint::Image {
    named_icon_in(&data_dirs(), icon, px)
        .and_then(|p| slint::Image::load_from_path(&p).ok())
        .unwrap_or_default()
}

fn named_icon_in(dirs: &[PathBuf], icon: &str, px: u32) -> Option<PathBuf> {
    if icon.is_empty() || icon.starts_with('.') {
        return None;
    }
    if Path::new(icon).is_absolute() {
        return Some(PathBuf::from(icon)).filter(|p| p.is_file());
    }
    if icon.contains('/') {
        return None;
    }
    let found = |want: &dyn Fn(u32) -> bool| {
        dirs.iter()
            .flat_map(|d| {
                CANDIDATES
                    .iter()
                    .map(move |(c, n)| (d.join(c.replace("{}", icon)), *n))
            })
            .filter(|(_, n)| want(*n))
            .map(|(p, _)| p)
            .find(|p| p.is_file())
    };
    // Scalable and unsized files draw sharp at any size; then the smallest PNG that is big
    // enough; if none is, the biggest there is.
    found(&|n| n == 0 || n >= px).or_else(|| {
        CANDIDATES
            .iter()
            .rev()
            .filter(|(_, n)| *n > 0)
            .find_map(|(c, _)| {
                dirs.iter()
                    .map(|d| d.join(c.replace("{}", icon)))
                    .find(|p| p.is_file())
            })
    })
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

/// `$XDG_DATA_HOME` (default `~/.local/share`), Flatpak's user and system export directories,
/// then `$XDG_DATA_DIRS` (default `/usr/local/share:/usr/share`). Flatpak's profile script puts
/// its exports into `$XDG_DATA_DIRS` in the same order, but a session started without a login
/// shell does not run it.
pub fn data_dirs() -> Vec<PathBuf> {
    let var = |k| std::env::var_os(k).filter(|v| !v.is_empty());
    let home = var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| var("HOME").map(|h| PathBuf::from(h).join(".local/share")));
    let flatpak_user =
        var("HOME").map(|h| PathBuf::from(h).join(".local/share/flatpak/exports/share"));
    let rest = var("XDG_DATA_DIRS").unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    let mut dirs: Vec<PathBuf> = Vec::new();
    for d in home
        .into_iter()
        .chain(flatpak_user)
        .chain([PathBuf::from("/var/lib/flatpak/exports/share")])
        .chain(std::env::split_paths(&rest))
    {
        if !dirs.contains(&d) {
            dirs.push(d);
        }
    }
    dirs
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
            icon_path_in(&dirs, "org.example.App", 40),
            Some(b.join("icons/hicolor/48x48/apps/example-app.png"))
        );
        // No desktop entry: the app ID is the icon name.
        assert_eq!(
            icon_path_in(&dirs, "other", 40),
            Some(b.join("icons/hicolor/scalable/apps/other.svg"))
        );
        assert_eq!(icon_path_in(&dirs, "missing", 40), None);

        // The PNG is picked for the physical size: the smallest one that is big enough, else the
        // biggest there is.
        std::fs::create_dir_all(b.join("icons/hicolor/128x128/apps")).unwrap();
        std::fs::write(b.join("icons/hicolor/128x128/apps/example-app.png"), "").unwrap();
        let pick = |px| icon_path_in(&dirs, "org.example.App", px).unwrap();
        assert_eq!(pick(40), b.join("icons/hicolor/48x48/apps/example-app.png"));
        assert_eq!(
            pick(60),
            b.join("icons/hicolor/128x128/apps/example-app.png")
        );
        assert_eq!(
            pick(80),
            b.join("icons/hicolor/128x128/apps/example-app.png")
        );
        assert_eq!(
            pick(500),
            b.join("icons/hicolor/128x128/apps/example-app.png")
        );
        assert_eq!(icon_path_in(&dirs, "../a/applications/x", 40), None);
        std::fs::remove_dir_all(root).unwrap();
    }
}
