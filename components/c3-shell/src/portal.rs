// SPDX-License-Identifier: MIT OR Apache-2.0
//! Publishes the shell's dark-mode setting to apps (owner decision on #65): the shell is an
//! xdg-desktop-portal *backend* for `org.freedesktop.impl.portal.Settings`, so
//! `org.freedesktop.appearance color-scheme` follows the control centre's Dark mode tile and apps
//! (GTK, Qt, libadwaita, Flatpak apps) read it through the portal. The portal merges every
//! backend's Settings, so no routing configuration is needed beyond `data/atos.portal`, which the
//! image installs as `/usr/share/xdg-desktop-portal/portals/atos.portal`.
//!
//! Runs on the session bus on its own thread (zbus serves the object there); the control centre
//! calls [`Portal::set_dark`], which updates the value and emits `SettingChanged`.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use zbus::blocking::{Connection, connection};
use zbus::zvariant::{OwnedValue, Value};

const NAME: &str = "org.freedesktop.impl.portal.desktop.atos";
const PATH: &str = "/org/freedesktop/portal/desktop";
const IFACE: &str = "org.freedesktop.impl.portal.Settings";
const NS: &str = "org.freedesktop.appearance";
const KEY: &str = "color-scheme";

/// The portal's `color-scheme` values: 1 prefers dark, 2 prefers light (0 is "no preference").
pub fn color_scheme(dark: bool) -> u32 {
    if dark { 1 } else { 2 }
}

/// Whether `namespace` is selected by a Settings `ReadAll`/`Read` namespace pattern: an exact
/// name, a prefix ending in `.*` (or `*`), or any pattern list that is empty.
pub fn matches(patterns: &[String], namespace: &str) -> bool {
    patterns.is_empty()
        || patterns.iter().any(|p| match p.strip_suffix('*') {
            Some(prefix) => namespace.starts_with(prefix.trim_end_matches('.')),
            None => p == namespace,
        })
}

struct Backend(Arc<AtomicBool>);

fn value(dark: bool) -> OwnedValue {
    OwnedValue::from(color_scheme(dark))
}

#[zbus::interface(name = "org.freedesktop.impl.portal.Settings")]
impl Backend {
    #[zbus(property(emits_changed_signal = "const"), name = "version")]
    fn version(&self) -> u32 {
        2
    }

    fn read_all(&self, namespaces: Vec<String>) -> HashMap<String, HashMap<String, OwnedValue>> {
        let mut all = HashMap::new();
        if matches(&namespaces, NS) {
            let dark = self.0.load(Ordering::Relaxed);
            all.insert(
                NS.to_string(),
                HashMap::from([(KEY.to_string(), value(dark))]),
            );
        }
        all
    }

    fn read(&self, namespace: String, key: String) -> zbus::fdo::Result<OwnedValue> {
        if namespace == NS && key == KEY {
            Ok(value(self.0.load(Ordering::Relaxed)))
        } else {
            Err(zbus::fdo::Error::Failed(format!(
                "unknown setting {namespace} {key}"
            )))
        }
    }
}

pub struct Portal {
    conn: Connection,
    dark: Arc<AtomicBool>,
}

impl Portal {
    /// Claims the backend name on the session bus. `None` (with a message) if there is no session
    /// bus or another process already owns the name; the tile then only re-themes the shell.
    pub fn start(dark: bool) -> Option<Portal> {
        let flag = Arc::new(AtomicBool::new(dark));
        let built = connection::Builder::session()
            .and_then(|b| b.name(NAME))
            .and_then(|b| b.serve_at(PATH, Backend(flag.clone())))
            .and_then(|b| b.build());
        match built {
            Ok(conn) => Some(Portal { conn, dark: flag }),
            Err(e) => {
                eprintln!("control centre: portal backend not started: {e}");
                None
            }
        }
    }

    /// Stores the new value and tells the portal, which tells the apps.
    pub fn set_dark(&self, dark: bool) {
        if self.dark.swap(dark, Ordering::Relaxed) == dark {
            return;
        }
        let v = Value::from(color_scheme(dark));
        if let Err(e) =
            self.conn
                .emit_signal(None::<&str>, PATH, IFACE, "SettingChanged", &(NS, KEY, v))
        {
            eprintln!("control centre: portal SettingChanged: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn color_scheme_follows_the_portal_enum() {
        assert_eq!(color_scheme(true), 1);
        assert_eq!(color_scheme(false), 2);
    }

    #[test]
    fn namespace_patterns() {
        assert!(matches(&[], NS));
        assert!(matches(&p(&[NS]), NS));
        assert!(matches(&p(&["org.freedesktop.*"]), NS));
        assert!(matches(&p(&["*"]), NS));
        assert!(!matches(&p(&["org.gnome.desktop.interface"]), NS));
        assert!(!matches(&p(&["org.freedesktopx.*"]), "org.gnome"));
    }

    #[test]
    fn read_returns_the_current_value() {
        let b = Backend(Arc::new(AtomicBool::new(true)));
        let v: u32 = b.read(NS.into(), KEY.into()).unwrap().try_into().unwrap();
        assert_eq!(v, 1);
        assert!(b.read("x".into(), KEY.into()).is_err());
        assert_eq!(b.read_all(p(&["org.gnome.*"])).len(), 0);
        assert_eq!(b.read_all(vec![]).len(), 1);
    }
}
