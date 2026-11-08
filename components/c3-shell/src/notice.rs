// SPDX-License-Identifier: MIT OR Apache-2.0
//! The disk-not-sealed notice (#138). `atos-tpm-seal` (C11) writes `/run/atos/disk-unsealed` while
//! the install-time TPM2 slot, bound to no PCRs, is still the disk's unlock; `/run` is empty at
//! every boot and the unit stops running once the seal succeeds, so the file's presence is the
//! state. The shell never touches cryptsetup. Interface documented in the C11 README.

use std::path::Path;

pub const STATE_FILE: &str = "/run/atos/disk-unsealed";

/// Where "Learn more" goes: the installer's page on the seal and its known gaps.
pub const DOCS_URL: &str =
    "https://github.com/jens-thomae/Atos/blob/main/docs/components/c11-installer/README.md";

pub const TITLE: &str = "Your disk is not protected from other systems";
pub const BODY: &str = "Anyone who can start another system on this computer, for example from a USB stick, can read your files without a password. To fix this, turn on Secure Boot in your firmware settings.";

pub fn unsealed(state_file: &Path) -> bool {
    state_file.exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_file_is_the_state() {
        let f = std::env::temp_dir().join(format!("atos-shell-notice-{}", std::process::id()));
        std::fs::remove_file(&f).ok();
        assert!(!unsealed(&f));
        std::fs::write(&f, "Secure Boot is off.\n").unwrap();
        assert!(unsealed(&f));
        std::fs::remove_file(&f).unwrap();
        assert!(!unsealed(&f));
    }
}
