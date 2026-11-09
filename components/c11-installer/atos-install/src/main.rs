//! atos-install (C11, #66): puts the sealed Atos image on an empty disk, encrypted by default.
//!
//! Text mode, run from the installer ISO. Layout: GPT with an ESP and a LUKS2 root partition
//! typed as the discoverable root, so the sealed UKI's fixed command line needs no `root=`:
//! systemd-gpt-auto-generator finds and unlocks it. Keyslots at the end of the install:
//! a recovery key, shown once, and a TPM2 slot bound to no PCRs (this machine's TPM only).
//! On first boot `atos-tpm-seal` replaces that slot with one bound to PCR7 (+PCR14 on B2).
//! Docs: docs/components/c11-installer/README.md.

use std::fs;
use std::io::{self, BufRead, Write};
use std::path::Path;
use std::process::{Command, ExitCode};
use std::time::Instant;

const SEAL_SCRIPT: &str = include_str!("../../firstboot/atos-tpm-seal.sh");
const SEAL_UNIT: &str = include_str!("../../firstboot/atos-tpm-seal.service");

const MAPPER: &str = "atos-root";
const TARGET: &str = "/run/atos-install/target";
const KEYFILE: &str = "/run/atos-install/install.key";
const STORAGE_CONF: &str = "/run/atos-install/storage.conf";
/// Install-only trust policy (#176), shipped on the ISO (`install-policy.json`). The image's own
/// policy rejects local `containers-storage` images (#150), but `bootc install` reads its own image
/// from local storage. Only the install container gets this file; the installed system has none.
const INSTALL_POLICY: &str = "/usr/share/atos-install/install-policy.json";
const STORAGE_CONF_TOML: &str = r#"[storage]
driver = "overlay"
graphroot = "/run/atos-install/storage"
runroot = "/run/atos-install/runroot"
[storage.options]
additionalimagestores = ["/var/lib/containers/storage"]
"#;

struct Args {
    disk: Option<String>,
    yes: bool,
    target_imgref: String,
}

fn usage() -> ! {
    eprintln!(
        "usage: atos-install [--disk DEVICE] [--yes] [--target-imgref IMGREF]\n\
         \n\
         Erases DEVICE and installs Atos, encrypted. Without --disk, asks which disk.\n\
         --yes            do not ask anything (tests only)\n\
         --target-imgref  image to install and update from; the ISO carries it offline"
    );
    std::process::exit(2)
}

fn parse_args(mut it: impl Iterator<Item = String>) -> Args {
    let mut a = Args {
        disk: None,
        yes: false,
        target_imgref: "ghcr.io/jens-thomae/atos/c1-base:latest".into(),
    };
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--disk" => a.disk = Some(it.next().unwrap_or_else(|| usage())),
            "--yes" => a.yes = true,
            "--target-imgref" => a.target_imgref = it.next().unwrap_or_else(|| usage()),
            _ => usage(),
        }
    }
    a
}

/// `/dev/vda` → `/dev/vda2`, `/dev/nvme0n1` → `/dev/nvme0n1p2`.
fn partition(disk: &str, n: u8) -> String {
    let sep = if disk.ends_with(|c: char| c.is_ascii_digit()) {
        "p"
    } else {
        ""
    };
    format!("{disk}{sep}{n}")
}

/// Discoverable Partitions Specification root type for this architecture.
fn root_type(arch: &str) -> Option<&'static str> {
    match arch {
        "x86_64" => Some("4f68bce3-e8cd-4db1-96e7-fbcaf984b709"),
        "aarch64" => Some("b921b045-1df0-41c3-af44-4c6f280d3fae"),
        _ => None,
    }
}

fn sfdisk_script(root_type: &str) -> String {
    format!(
        "label: gpt\n\
         size=1GiB, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name=\"esp\"\n\
         type={root_type}, name=\"root\"\n"
    )
}

fn run(cmd: &mut Command) -> Result<(), String> {
    let status = cmd.status().map_err(|e| format!("{cmd:?}: {e}"))?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| format!("{cmd:?} failed: {status}"))
}

fn sh(args: &[&str]) -> Result<(), String> {
    run(Command::new(args[0]).args(&args[1..]))
}

/// Whole disks that hold no mounted filesystem (so not the installer's own media).
fn candidate_disks() -> Result<Vec<String>, String> {
    let out = Command::new("lsblk")
        .args(["-dnpo", "NAME,TYPE,SIZE,MODEL"])
        .output()
        .map_err(|e| e.to_string())?;
    let mut disks = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let mut f = line.split_whitespace();
        let (Some(name), Some("disk")) = (f.next(), f.next()) else {
            continue;
        };
        let mounts = Command::new("lsblk")
            .args(["-nro", "MOUNTPOINTS", name])
            .output()
            .map_err(|e| e.to_string())?;
        if String::from_utf8_lossy(&mounts.stdout).trim().is_empty() {
            disks.push(line.to_string());
        }
    }
    Ok(disks)
}

fn ask(prompt: &str) -> String {
    print!("{prompt}");
    io::stdout().flush().ok();
    let mut s = String::new();
    io::stdin().lock().read_line(&mut s).ok();
    s.trim().to_string()
}

fn choose_disk() -> Result<String, String> {
    let disks = candidate_disks()?;
    if disks.is_empty() {
        return Err("no disk to install to".into());
    }
    println!("Disks:");
    for (i, d) in disks.iter().enumerate() {
        println!("  {}) {d}", i + 1);
    }
    let pick = ask("Install Atos on disk number: ");
    let i: usize = pick.parse().map_err(|_| format!("not a number: {pick}"))?;
    disks
        .get(i.wrapping_sub(1))
        .and_then(|l| l.split_whitespace().next())
        .map(str::to_string)
        .ok_or_else(|| format!("no disk {i}"))
}

fn install(a: &Args) -> Result<(), String> {
    let arch = std::env::consts::ARCH;
    let root_type = root_type(arch).ok_or_else(|| format!("unsupported architecture {arch}"))?;
    let disk = match &a.disk {
        Some(d) => d.clone(),
        None => choose_disk()?,
    };
    if !a.yes
        && ask(&format!(
            "Everything on {disk} will be erased. Type \"erase\" to continue: "
        )) != "erase"
    {
        return Err("cancelled, nothing changed".into());
    }
    let start = Instant::now();
    let (esp, root) = (partition(&disk, 1), partition(&disk, 2));
    let mapped = format!("/dev/mapper/{MAPPER}");

    println!("Partitioning {disk}");
    sh(&["wipefs", "--all", "--quiet", &disk])?;
    let mut sfdisk = Command::new("sfdisk")
        .args(["--quiet", "--wipe", "always", &disk])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    sfdisk
        .stdin
        .take()
        .ok_or("sfdisk stdin")?
        .write_all(sfdisk_script(root_type).as_bytes())
        .map_err(|e| e.to_string())?;
    let st = sfdisk.wait().map_err(|e| e.to_string())?;
    st.success().then_some(()).ok_or("sfdisk failed")?;
    sh(&["udevadm", "settle"])?;

    println!("Encrypting the root partition (LUKS2)");
    fs::create_dir_all(TARGET).map_err(|e| e.to_string())?;
    // A random install-time key in tmpfs; its slot is wiped before the installer exits.
    let mut key = [0u8; 64];
    fs::File::open("/dev/urandom")
        .and_then(|mut f| io::Read::read_exact(&mut f, &mut key))
        .map_err(|e| e.to_string())?;
    write_private(KEYFILE, &key)?;
    sh(&[
        "cryptsetup",
        "luksFormat",
        "--batch-mode",
        "--type",
        "luks2",
        "--key-file",
        KEYFILE,
        &root,
    ])?;
    println!(
        "\nYour recovery key follows. Write it down and keep it away from this computer.\n\
         You need it if the firmware, Secure Boot keys or the TPM change.\n"
    );
    let unlock = format!("--unlock-key-file={KEYFILE}");
    sh(&["systemd-cryptenroll", &unlock, "--recovery-key", &root])?;
    if !a.yes {
        ask("\nPress Enter once you have written the recovery key down. ");
    }
    // Until first boot: this machine's TPM, no PCRs (owner answer Q2 on #66).
    sh(&[
        "systemd-cryptenroll",
        &unlock,
        "--tpm2-device=auto",
        "--tpm2-pcrs=",
        &root,
    ])?;
    sh(&["cryptsetup", "open", "--key-file", KEYFILE, &root, MAPPER])?;

    println!("Creating file systems");
    // ext4 with fs-verity: sealed composefs needs it (as c1-base's 80-atos-rootfs.toml).
    sh(&["mkfs.ext4", "-q", "-O", "verity", "-L", "root", &mapped])?;
    sh(&["mkfs.vfat", "-F", "32", "-n", "ESP", &esp])?;
    sh(&["mount", &mapped, TARGET])?;
    let boot = format!("{TARGET}/boot");
    fs::create_dir_all(&boot).map_err(|e| e.to_string())?;
    sh(&["mount", &esp, &boot])?;

    println!("Installing {}", a.target_imgref);
    // The live root is an overlay, which cannot hold the container's upper layer: put podman's
    // own storage in tmpfs and read the ISO's payload as an additional (read-only) image store.
    write_private(STORAGE_CONF, STORAGE_CONF_TOML.as_bytes())?;
    sh(&[
        "env",
        &format!("CONTAINERS_STORAGE_CONF={STORAGE_CONF}"),
        "podman",
        "run",
        "--rm",
        "--privileged",
        "--pid=host",
        "--security-opt",
        "label=type:unconfined_t",
        "-v",
        "/dev:/dev",
        "-v",
        "/var/lib/containers:/var/lib/containers",
        "-v",
        &format!("{TARGET}:/target"),
        "-v",
        &format!("{INSTALL_POLICY}:/etc/containers/policy.json:ro"),
        "--pull=never",
        &a.target_imgref,
        "bootc",
        "install",
        "to-filesystem",
        "--target-imgref",
        &a.target_imgref,
        // No root= karg: the sealed UKI's command line is fixed; gpt-auto finds the root.
        "--root-mount-spec=",
        "/target",
    ])?;
    // bootc leaves the root mounted read-only when it is done.
    sh(&["mount", "-o", "remount,rw", TARGET])?;
    // The install policy must not reach the installed system: there the image's /usr policy applies.
    let leaked = deployment_etc(Path::new(TARGET))?.join("containers/policy.json");
    if leaked.exists() {
        return Err(format!("{} exists after the install", leaked.display()));
    }
    install_seal_unit(Path::new(TARGET))?;

    sh(&["umount", &boot])?;
    sh(&["umount", TARGET])?;
    // The install-time key is luksFormat's slot 0; the recovery and TPM2 slots remain.
    sh(&["systemd-cryptenroll", &unlock, "--wipe-slot=0", &root])?;
    sh(&["cryptsetup", "close", MAPPER])?;
    fs::remove_file(KEYFILE).map_err(|e| e.to_string())?;

    println!(
        "\nAtos is installed on {disk} in {} s. Remove the installer media and restart.",
        start.elapsed().as_secs()
    );
    if !a.yes {
        ask("Press Enter to restart. ");
    }
    Ok(())
}

fn write_private(path: &str, data: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .and_then(|mut f| f.write_all(data))
        .map_err(|e| format!("{path}: {e}"))
}

/// Writes the first-boot seal unit into the deployment's /etc (outside the sealed /usr).
fn install_seal_unit(target: &Path) -> Result<(), String> {
    let etc = deployment_etc(target)?;
    let unit_dir = etc.join("systemd/system");
    let wants = unit_dir.join("multi-user.target.wants");
    fs::create_dir_all(&wants).map_err(|e| e.to_string())?;
    fs::create_dir_all(etc.join("atos")).map_err(|e| e.to_string())?;
    fs::write(etc.join("atos/atos-tpm-seal.sh"), SEAL_SCRIPT).map_err(|e| e.to_string())?;
    fs::write(unit_dir.join("atos-tpm-seal.service"), SEAL_UNIT).map_err(|e| e.to_string())?;
    let link = wants.join("atos-tpm-seal.service");
    std::os::unix::fs::symlink("/etc/systemd/system/atos-tpm-seal.service", &link)
        .map_err(|e| e.to_string())?;
    // bootc has already labelled the tree; give the new files their neighbours' SELinux labels.
    let label = |reference: &Path, file: &Path| {
        let (r, f) = (reference.to_string_lossy(), file.to_string_lossy());
        sh(&["chcon", "-h", &format!("--reference={r}"), &f])
    };
    label(&etc, &etc.join("atos"))?;
    label(&etc.join("DIR_COLORS"), &etc.join("atos/atos-tpm-seal.sh"))?;
    label(&unit_dir, &wants)?;
    label(&unit_dir, &unit_dir.join("atos-tpm-seal.service"))?;
    label(&unit_dir, &link)
}

/// The composefs backend keeps each deployment's /etc in `state/deploy/<id>/etc`.
fn deployment_etc(target: &Path) -> Result<std::path::PathBuf, String> {
    let deploy = target.join("state/deploy");
    let mut ids = fs::read_dir(&deploy)
        .map_err(|e| format!("{}: {e}", deploy.display()))?
        .filter_map(Result::ok)
        .map(|e| e.path());
    match (ids.next(), ids.next()) {
        (Some(id), None) => Ok(id.join("etc")),
        _ => Err(format!("expected one deployment in {}", deploy.display())),
    }
}

fn main() -> ExitCode {
    let a = parse_args(std::env::args().skip(1));
    match install(&a) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("atos-install: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partition_names() {
        assert_eq!(partition("/dev/vda", 2), "/dev/vda2");
        assert_eq!(partition("/dev/sda", 1), "/dev/sda1");
        assert_eq!(partition("/dev/nvme0n1", 2), "/dev/nvme0n1p2");
        assert_eq!(partition("/dev/mmcblk0", 1), "/dev/mmcblk0p1");
    }

    #[test]
    fn root_is_discoverable() {
        let s = sfdisk_script(root_type("x86_64").unwrap());
        assert!(s.contains("type=4f68bce3-e8cd-4db1-96e7-fbcaf984b709"));
        assert!(s.contains("type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b"));
        assert_eq!(root_type("riscv64"), None);
    }

    #[test]
    fn args() {
        let a = parse_args(
            ["--disk", "/dev/vdb", "--yes"]
                .map(String::from)
                .into_iter(),
        );
        assert_eq!(a.disk.as_deref(), Some("/dev/vdb"));
        assert!(a.yes);
        assert_eq!(a.target_imgref, "ghcr.io/jens-thomae/atos/c1-base:latest");
    }

    #[test]
    fn install_policy_accepts_only_the_payload_store() {
        let p = include_str!("../../install-policy.json");
        assert!(p.contains(r#""default": [{ "type": "reject" }]"#));
        assert!(p.contains(
            r#""[overlay@/var/lib/containers/storage]": [{ "type": "insecureAcceptAnything" }]"#
        ));
        assert_eq!(p.matches("insecureAcceptAnything").count(), 1);
    }

    #[test]
    fn seal_script_fails_closed_and_binds_pcr7() {
        assert!(SEAL_SCRIPT.contains("--tpm2-pcrs=\"$pcrs\""));
        assert!(SEAL_SCRIPT.contains("pcrs=7"));
        assert!(SEAL_SCRIPT.contains("efi_byte SecureBoot)\" = 1 ] || warn"));
        assert!(SEAL_SCRIPT.contains("can read the disk without a password"));
    }
}
