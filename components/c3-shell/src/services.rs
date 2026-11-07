// SPDX-License-Identifier: MIT OR Apache-2.0
//! The system services behind the control centre, all over D-Bus (no new daemons; #65):
//! NetworkManager (Wi-Fi), BlueZ (Bluetooth), power-profiles-daemon (power profile) and logind
//! (backlight, suspend, reboot, power off). Calls block, so the shell runs them on a worker thread
//! (`control_centre.rs`). A missing service reads as `None`: its tile is shown disabled.

use std::collections::HashMap;
use std::sync::Mutex;

use atos_shell::control::Radio;
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

type Result<T> = std::result::Result<T, zbus::Error>;

fn system() -> Result<Connection> {
    static CONN: Mutex<Option<Connection>> = Mutex::new(None);
    let mut c = CONN.lock().unwrap_or_else(|e| e.into_inner());
    if c.is_none() {
        *c = Some(Connection::system()?);
    }
    Ok(c.clone().expect("set above"))
}

fn proxy(dest: &'static str, path: &str, iface: &'static str) -> Result<Proxy<'static>> {
    Proxy::new(&system()?, dest, path.to_string(), iface)
}

const NM: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const BLUEZ: &str = "org.bluez";
const PPD: &str = "net.hadess.PowerProfiles";
const PPD_PATH: &str = "/net/hadess/PowerProfiles";
const LOGIN: &str = "org.freedesktop.login1";

/// Wi-Fi: the radio switch and the connection of the first Wi-Fi device. `None` without
/// NetworkManager or a Wi-Fi device.
pub fn wifi() -> Option<Radio> {
    let nm = proxy(NM, NM_PATH, NM).ok()?;
    let devices: Vec<OwnedObjectPath> = nm.call("GetDevices", &()).ok()?;
    let mut detail = None;
    let mut found = false;
    for d in devices {
        let dev = proxy(NM, d.as_str(), "org.freedesktop.NetworkManager.Device").ok()?;
        // NM_DEVICE_TYPE_WIFI
        if dev.get_property::<u32>("DeviceType").ok() != Some(2) {
            continue;
        }
        found = true;
        if let Ok(active) = dev.get_property::<OwnedObjectPath>("ActiveConnection")
            && active.as_str() != "/"
            && let Ok(a) = proxy(
                NM,
                active.as_str(),
                "org.freedesktop.NetworkManager.Connection.Active",
            )
        {
            detail = a.get_property::<String>("Id").ok();
            break;
        }
    }
    if !found {
        return None;
    }
    let on = nm.get_property::<bool>("WirelessEnabled").ok()?;
    Some(Radio {
        on,
        detail: detail.unwrap_or_default(),
    })
}

pub fn set_wifi(on: bool) -> Result<()> {
    Ok(proxy(NM, NM_PATH, NM)?.set_property("WirelessEnabled", on)?)
}

type Managed = HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>;

fn bluez_objects() -> Result<Managed> {
    proxy(BLUEZ, "/", "org.freedesktop.DBus.ObjectManager")?.call("GetManagedObjects", &())
}

/// Bluetooth: the first adapter's power and the name of a connected device.
pub fn bluetooth() -> Option<Radio> {
    let objects = bluez_objects().ok()?;
    let mut adapters: Vec<_> = objects
        .iter()
        .filter(|(_, i)| i.contains_key("org.bluez.Adapter1"))
        .collect();
    adapters.sort_by(|a, b| a.0.as_str().cmp(b.0.as_str()));
    let (_, ifaces) = adapters.first()?;
    let on = bool::try_from(
        ifaces["org.bluez.Adapter1"]
            .get("Powered")?
            .try_clone()
            .ok()?,
    )
    .ok()?;
    let mut names: Vec<String> = objects
        .values()
        .filter_map(|i| i.get("org.bluez.Device1"))
        .filter(|d| {
            d.get("Connected")
                .and_then(|v| bool::try_from(v.try_clone().ok()?).ok())
                == Some(true)
        })
        .filter_map(|d| String::try_from(d.get("Alias")?.try_clone().ok()?).ok())
        .collect();
    names.sort();
    Some(Radio {
        on,
        detail: names.into_iter().next().unwrap_or_default(),
    })
}

pub fn set_bluetooth(on: bool) -> Result<()> {
    let objects = bluez_objects()?;
    let mut paths: Vec<_> = objects
        .iter()
        .filter(|(_, i)| i.contains_key("org.bluez.Adapter1"))
        .map(|(p, _)| p.clone())
        .collect();
    paths.sort_by(|a, b| a.as_str().cmp(b.as_str()));
    let path = paths
        .first()
        .ok_or_else(|| zbus::Error::Failure("no Bluetooth adapter".into()))?;
    Ok(proxy(BLUEZ, path.as_str(), "org.bluez.Adapter1")?.set_property("Powered", on)?)
}

/// The active power profile and the ones the machine offers, in daemon order.
pub fn profiles() -> Option<(String, Vec<String>)> {
    let p = proxy(PPD, PPD_PATH, PPD).ok()?;
    let active = p.get_property::<String>("ActiveProfile").ok()?;
    let list: Vec<HashMap<String, OwnedValue>> = p.get_property("Profiles").ok()?;
    let names = list
        .iter()
        .filter_map(|m| String::try_from(m.get("Profile")?.try_clone().ok()?).ok())
        .collect();
    Some((active, names))
}

/// The profile after `active` in `names`, wrapping round.
pub fn next_profile(active: &str, names: &[String]) -> Option<String> {
    let i = names.iter().position(|n| n == active).map_or(0, |i| i + 1);
    names.get(i % names.len().max(1)).cloned()
}

pub fn cycle_profile() -> Result<()> {
    let (active, names) =
        profiles().ok_or_else(|| zbus::Error::Failure("no power-profiles-daemon".into()))?;
    let next =
        next_profile(&active, &names).ok_or_else(|| zbus::Error::Failure("no profile".into()))?;
    Ok(proxy(PPD, PPD_PATH, PPD)?.set_property("ActiveProfile", next)?)
}

/// First backlight device: (name, brightness, maximum). Read from sysfs; logind does the writing.
fn backlight() -> Option<(String, u32, u32)> {
    let dir = std::fs::read_dir("/sys/class/backlight")
        .ok()?
        .flatten()
        .min_by_key(|e| e.file_name())?;
    let read = |f: &str| {
        std::fs::read_to_string(dir.path().join(f))
            .ok()?
            .trim()
            .parse::<u32>()
            .ok()
    };
    Some((
        dir.file_name().to_string_lossy().into_owned(),
        read("brightness")?,
        read("max_brightness")?,
    ))
}

/// Brightness as 0.0..=1.0; `None` without a backlight (the slider is then disabled).
pub fn brightness() -> Option<f32> {
    let (_, now, max) = backlight()?;
    (max > 0).then(|| now as f32 / max as f32)
}

pub fn set_brightness(v: f32) -> Result<()> {
    let (name, _, max) = backlight().ok_or_else(|| zbus::Error::Failure("no backlight".into()))?;
    // Never to 0: a black screen with no way back is not a brightness setting.
    let value = ((v.clamp(0., 1.) * max as f32).round() as u32).max(1);
    proxy(
        LOGIN,
        "/org/freedesktop/login1/session/auto",
        "org.freedesktop.login1.Session",
    )?
    .call::<_, _, ()>("SetBrightness", &("backlight", name, value))
}

/// logind's Manager methods behind the Power options menu.
pub fn power(action: &str) -> Result<()> {
    let method = match action {
        "suspend" => "Suspend",
        "reboot" => "Reboot",
        "poweroff" => "PowerOff",
        other => {
            return Err(zbus::Error::Failure(format!(
                "unknown power action {other}"
            )));
        }
    };
    proxy(
        LOGIN,
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )?
    .call::<_, _, ()>(method, &(true,)) // interactive: polkit may ask
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profiles_cycle_and_wrap() {
        let n: Vec<String> = ["power-saver", "balanced", "performance"]
            .map(String::from)
            .to_vec();
        assert_eq!(next_profile("balanced", &n).as_deref(), Some("performance"));
        assert_eq!(
            next_profile("performance", &n).as_deref(),
            Some("power-saver")
        );
        assert_eq!(next_profile("unknown", &n).as_deref(), Some("power-saver"));
        assert_eq!(next_profile("x", &[]), None);
    }
}
