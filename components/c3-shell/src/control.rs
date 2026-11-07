// SPDX-License-Identifier: MIT OR Apache-2.0
//! The control centre's tiles as data: what each shows for the current state of the system. The
//! services that fill `Quick` are in the binary (`services.rs`, `audio.rs`).

use crate::Tile;

/// Where the privacy chip's text comes from ("Microphone · Meetings") while camera, microphone or
/// screen capture is active (spec §6 C3). Nothing implements it yet (owner decision on #65): the
/// chip stays hidden until a source exists and is handed to the control centre.
pub trait PrivacySource {
    /// The chip text, or `None` while nothing is being captured.
    fn chip(&self) -> Option<String>;
}

/// The window's chip text: empty (hidden) without a source or while nothing is captured.
pub fn chip_text(source: Option<&dyn PrivacySource>) -> String {
    source.and_then(PrivacySource::chip).unwrap_or_default()
}

/// A switchable radio (Wi-Fi, Bluetooth): on or off, plus the connection or device in use.
#[derive(Clone, Debug, PartialEq)]
pub struct Radio {
    pub on: bool,
    pub detail: String,
}

/// State behind the tiles. `None` means the service or hardware is missing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Quick {
    pub wifi: Option<Radio>,
    pub bluetooth: Option<Radio>,
    pub do_not_disturb: bool,
    pub dark_mode: bool,
    /// The active power profile as power-profiles-daemon names it.
    pub profile: Option<String>,
}

const WIFI: &str =
    "M3.5 9.5a12 12 0 0 1 17 0M6.5 12.8a7.5 7.5 0 0 1 11 0M9.5 16a3.2 3.2 0 0 1 5 0M12 19h.01";
const BLUETOOTH: &str = "M7 7.5l10 9-5 4V3.5l5 4-10 9";
const MOON: &str = "M19 14.5A8 8 0 1 1 9.5 5a6.5 6.5 0 0 0 9.5 9.5z";
const CONTRAST: &str = "M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17zM12 3.5v17";
const BOLT: &str = "M13 3.5L6 13.5h5.5l-1 7 7-10H12z";
const RECORD: &str =
    "M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17zM12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z";

pub fn profile_label(profile: &str) -> &str {
    match profile {
        "power-saver" => "Power saver",
        "balanced" => "Balanced",
        "performance" => "Performance",
        other => other,
    }
}

fn radio(id: &str, name: &str, glyph: &str, r: &Option<Radio>) -> Tile {
    let (on, enabled, state) = match r {
        None => (false, false, "Unavailable".to_string()),
        Some(r) if r.on && !r.detail.is_empty() => (true, true, r.detail.clone()),
        Some(r) => (r.on, true, if r.on { "On" } else { "Off" }.to_string()),
    };
    Tile {
        id: id.into(),
        name: name.into(),
        state: state.into(),
        on,
        enabled,
        glyph: glyph.into(),
    }
}

fn switch(id: &str, name: &str, glyph: &str, on: bool) -> Tile {
    radio(
        id,
        name,
        glyph,
        &Some(Radio {
            on,
            detail: String::new(),
        }),
    )
}

/// The six tiles in display order (two columns, row by row).
pub fn tiles(q: &Quick) -> Vec<Tile> {
    vec![
        radio("wifi", "Wi-Fi", WIFI, &q.wifi),
        radio("bluetooth", "Bluetooth", BLUETOOTH, &q.bluetooth),
        switch("dnd", "Do not disturb", MOON, q.do_not_disturb),
        switch("dark", "Dark mode", CONTRAST, q.dark_mode),
        Tile {
            id: "profile".into(),
            name: "Power".into(),
            state: q
                .profile
                .as_deref()
                .map_or("Unavailable", profile_label)
                .into(),
            on: false,
            enabled: q.profile.is_some(),
            glyph: BOLT.into(),
        },
        // No recorder service exists yet (owner decision on #65): shown, not actionable.
        Tile {
            id: "record".into(),
            name: "Record screen".into(),
            state: "Not available yet".into(),
            on: false,
            enabled: false,
            glyph: RECORD.into(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_chip_is_hidden_without_a_source_or_capture() {
        struct Fake(Option<&'static str>);
        impl PrivacySource for Fake {
            fn chip(&self) -> Option<String> {
                self.0.map(String::from)
            }
        }
        assert_eq!(chip_text(None), "");
        assert_eq!(chip_text(Some(&Fake(None))), "");
        assert_eq!(
            chip_text(Some(&Fake(Some("Microphone · Meetings")))),
            "Microphone · Meetings"
        );
    }

    #[test]
    fn missing_services_are_disabled_and_record_always_is() {
        let t = tiles(&Quick::default());
        let by = |id: &str| t.iter().find(|t| t.id == id).unwrap().clone();
        assert!(!by("wifi").enabled && by("wifi").state == "Unavailable");
        assert!(!by("profile").enabled);
        assert!(by("dnd").enabled && by("dark").enabled);
        assert!(!by("record").enabled && by("record").state == "Not available yet");
    }

    #[test]
    fn a_connected_radio_shows_its_connection() {
        let q = Quick {
            wifi: Some(Radio {
                on: true,
                detail: "Home-5G".into(),
            }),
            bluetooth: Some(Radio {
                on: false,
                detail: String::new(),
            }),
            profile: Some("power-saver".into()),
            ..Quick::default()
        };
        let t = tiles(&q);
        assert!(t[0].on && t[0].state == "Home-5G");
        assert!(!t[1].on && t[1].state == "Off");
        assert_eq!(t[4].state, "Power saver");
    }
}
