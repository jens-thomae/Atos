// SPDX-License-Identifier: MIT OR Apache-2.0
//! Installed apps for the launcher (#64): the desktop entries (freedesktop Desktop Entry spec)
//! in `applications/` of the XDG data directories, Flatpak's export directories included
//! (`icons::data_dirs`), and the search over their names.
//!
//! ponytail: no `Name[xx]` translations (the shell is English-only for now), no subdirectories
//! of `applications/`, field codes are dropped (the launcher opens no files), and
//! `Terminal=true` entries are left out until a terminal app exists (C5). Add each when needed.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct App {
    /// Desktop file ID, such as `org.gnome.Calculator.desktop`.
    pub id: String,
    pub name: String,
    /// `Icon=`: a name in the icon theme or an absolute path.
    pub icon: String,
    /// The command line from `Exec=`, split and unquoted, field codes removed.
    pub argv: Vec<String>,
    /// `Path=`: the working directory, if set.
    pub dir: Option<PathBuf>,
}

/// Every app to list, sorted by name.
pub fn installed() -> Vec<App> {
    let desktops = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
    installed_in(&crate::icons::data_dirs(), &desktops)
}

/// `desktops` is `$XDG_CURRENT_DESKTOP` (colon-separated), for `OnlyShowIn` and `NotShowIn`.
pub fn installed_in(dirs: &[PathBuf], desktops: &str) -> Vec<App> {
    let desktops: Vec<&str> = desktops.split(':').filter(|d| !d.is_empty()).collect();
    // The first directory with a given ID wins, even when that entry is hidden (spec: Hidden).
    let mut seen = HashSet::new();
    let mut apps = Vec::new();
    for dir in dirs {
        let Ok(files) = std::fs::read_dir(dir.join("applications")) else {
            continue;
        };
        let mut files: Vec<PathBuf> = files.flatten().map(|f| f.path()).collect();
        files.sort();
        for path in files {
            let Some(id) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if !id.ends_with(".desktop") || !seen.insert(id.to_owned()) {
                continue;
            }
            if let Some(app) = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| parse(id, &t, &desktops))
            {
                apps.push(app);
            }
        }
    }
    apps.sort_by_cached_key(|a| (a.name.to_lowercase(), a.id.clone()));
    apps
}

/// One desktop entry, or `None` if the launcher should not list it.
fn parse(id: &str, text: &str, desktops: &[&str]) -> Option<App> {
    let mut in_entry = false;
    let mut get = std::collections::HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry
            && !line.starts_with('#')
            && let Some((k, v)) = line.split_once('=')
        {
            get.entry(k.trim()).or_insert(v.trim());
        }
    }
    let key = |k| get.get(k).copied().unwrap_or("");
    let listed = |k| key(k).split(';').any(|d| desktops.contains(&d));
    if key("Type") != "Application"
        || key("NoDisplay") == "true"
        || key("Hidden") == "true"
        || key("Terminal") == "true"
        || (!key("OnlyShowIn").is_empty() && !listed("OnlyShowIn"))
        || listed("NotShowIn")
        || (!key("TryExec").is_empty() && !on_path(&unescape(key("TryExec"))))
    {
        return None;
    }
    let name = unescape(key("Name"));
    let argv = exec_argv(key("Exec"))?;
    if name.is_empty() {
        return None;
    }
    Some(App {
        id: id.to_owned(),
        name,
        icon: unescape(key("Icon")),
        argv,
        dir: Some(unescape(key("Path")))
            .filter(|p| !p.is_empty())
            .map(PathBuf::from),
    })
}

/// The spec's escapes for string values: `\s`, `\n`, `\t`, `\r`, `\\`.
fn unescape(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    let mut chars = v.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            // Not a string escape: kept, so Exec's own quoting (`\"`) still sees it.
            Some(o) => {
                out.push('\\');
                out.push(o);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Splits `Exec=` into arguments: string escapes first, then double quotes (inside them `\"`,
/// `` \` ``, `\$` and `\\` are escapes), then field codes. `%%` is a literal `%`; every other
/// field code is dropped, and an argument that was only a field code goes away.
pub fn exec_argv(exec: &str) -> Option<Vec<String>> {
    let exec = unescape(exec);
    let mut argv = Vec::new();
    let mut arg = String::new();
    let (mut started, mut quoted) = (false, false);
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            '\\' if quoted => arg.push(chars.next()?),
            c if c.is_whitespace() && !quoted => {
                if started {
                    argv.push(std::mem::take(&mut arg));
                }
                started = false;
            }
            '%' => {
                match chars.next()? {
                    '%' => arg.push('%'),
                    _ if !started && chars.peek().is_none_or(|c| c.is_whitespace()) => {
                        continue; // a lone field code: no argument at all
                    }
                    _ => {}
                }
                started = true;
            }
            c => {
                arg.push(c);
                started = true;
            }
        }
    }
    if quoted {
        return None;
    }
    if started {
        argv.push(arg);
    }
    Some(argv).filter(|a| !a.is_empty())
}

/// `TryExec`: an absolute path that exists, or a name found in `$PATH`.
fn on_path(cmd: &str) -> bool {
    if Path::new(cmd).is_absolute() {
        return Path::new(cmd).is_file();
    }
    std::env::var_os("PATH")
        .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(cmd).is_file()))
}

/// The apps whose name matches `query`, best first: name starts with it, then a word starts
/// with it, then it appears anywhere; ties by name. Case-insensitive. Empty query: all apps.
pub fn search<'a>(apps: &'a [App], query: &str) -> Vec<&'a App> {
    let q = query.trim().to_lowercase();
    let mut hits: Vec<(u8, &App)> = apps
        .iter()
        .filter_map(|a| {
            let name = a.name.to_lowercase();
            let rank = if name.starts_with(&q) {
                0
            } else if name
                .split(|c: char| !c.is_alphanumeric())
                .any(|w| w.starts_with(&q))
            {
                1
            } else if name.contains(&q) {
                2
            } else {
                return None;
            };
            Some((rank, a))
        })
        .collect();
    hits.sort_by_key(|(rank, _)| *rank); // stable: `apps` is already sorted by name
    hits.into_iter().map(|(_, a)| a).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn exec_lines_split_like_the_spec() {
        assert_eq!(exec_argv("gedit %U"), Some(s(&["gedit"])));
        assert_eq!(
            exec_argv(r#""/opt/My App/run" --name "a \"b\"" 100%%"#),
            Some(s(&["/opt/My App/run", "--name", "a \"b\"", "100%"]))
        );
        // Flatpak's exported entries.
        assert_eq!(
            exec_argv(
                "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=calc org.x.Calc @@u %U @@"
            ),
            Some(s(&[
                "/usr/bin/flatpak",
                "run",
                "--branch=stable",
                "--arch=x86_64",
                "--command=calc",
                "org.x.Calc",
                "@@u",
                "@@"
            ]))
        );
        assert_eq!(
            exec_argv(r"sh -c 'echo\sx'"),
            Some(s(&["sh", "-c", "'echo", "x'"]))
        );
        assert_eq!(exec_argv("--file=%f app"), Some(s(&["--file=", "app"])));
        assert_eq!(exec_argv(r#"unterminated "quote"#), None);
        assert_eq!(exec_argv("%U"), None);
    }

    #[test]
    fn lists_visible_apps_with_precedence() {
        let root = std::env::temp_dir().join(format!("atos-shell-apps-{}", std::process::id()));
        let (user, flatpak, system) = (root.join("u"), root.join("f"), root.join("s"));
        for d in [&user, &flatpak, &system] {
            std::fs::create_dir_all(d.join("applications")).unwrap();
        }
        let entry = |dir: &PathBuf, id: &str, body: &str| {
            std::fs::write(
                dir.join("applications").join(id),
                format!(
                    "[Desktop Entry]\nType=Application\n{body}\n[Desktop Action x]\nName=Wrong\n"
                ),
            )
            .unwrap()
        };
        entry(
            &system,
            "calc.desktop",
            "Name=Calculator\nExec=calc %f\nIcon=calc",
        );
        entry(&user, "calc.desktop", "Name=My Calculator\nExec=calc");
        entry(&system, "hidden.desktop", "Name=Hidden\nExec=x");
        entry(&user, "hidden.desktop", "Name=Hidden\nExec=x\nHidden=true");
        entry(
            &flatpak,
            "org.x.Paint.desktop",
            "Name=paint\nExec=flatpak run org.x.Paint\nIcon=org.x.Paint",
        );
        entry(
            &system,
            "nodisplay.desktop",
            "Name=Helper\nExec=x\nNoDisplay=true",
        );
        entry(
            &system,
            "kde.desktop",
            "Name=KDE only\nExec=x\nOnlyShowIn=KDE;",
        );
        entry(
            &system,
            "notgnome.desktop",
            "Name=Not GNOME\nExec=x\nNotShowIn=GNOME;",
        );
        entry(
            &system,
            "tryexec.desktop",
            "Name=Missing\nExec=x\nTryExec=/nonexistent/x",
        );
        entry(&system, "term.desktop", "Name=Top\nExec=top\nTerminal=true");
        entry(&system, "link.desktop", "Name=Link\nType=Link");
        std::fs::write(system.join("applications/notes.txt"), "Name=x").unwrap();

        let apps = installed_in(&[user, flatpak, system], "GNOME");
        let names: Vec<&str> = apps.iter().map(|a| a.name.as_str()).collect();
        // Sorted case-insensitively; the user's calc.desktop shadows the system one.
        assert_eq!(names, ["My Calculator", "paint"]);
        assert_eq!(apps[0].argv, ["calc"]);
        assert_eq!(apps[1].icon, "org.x.Paint");
        assert_eq!(apps[1].id, "org.x.Paint.desktop");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn search_ranks_prefix_then_word_then_substring() {
        let app = |name: &str| App {
            id: format!("{name}.desktop"),
            name: name.into(),
            icon: String::new(),
            argv: vec!["x".into()],
            dir: None,
        };
        let apps = [
            app("Disk Usage"),
            app("Files"),
            app("Profiler"),
            app("File Roller"),
        ];
        let names = |q| -> Vec<&str> { search(&apps, q).iter().map(|a| a.name.as_str()).collect() };
        assert_eq!(names("fil"), ["Files", "File Roller", "Profiler"]);
        assert_eq!(names("  ROLL "), ["File Roller"]);
        assert_eq!(names("usage"), ["Disk Usage"]);
        assert_eq!(
            names(""),
            ["Disk Usage", "Files", "Profiler", "File Roller"]
        );
        assert!(names("zzz").is_empty());
    }
}
