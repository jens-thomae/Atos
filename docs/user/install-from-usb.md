# Installing Atos from a USB stick

*Last checked against `main` on 2026-11-11.* How it works for developers: [installer docs](../components/c11-installer/README.md).

**Installing erases the whole disk you choose.** Everything on it is gone and cannot be brought back. Today Atos cannot be installed next to another system.

## What you need

- The installer image (`atos-install-….iso`) written to a USB stick of at least 4 GB, for example with Fedora Media Writer, balenaEtcher or `dd`. Writing it erases the stick.
- A computer with a TPM 2.0 (most computers from the last years have one; in the firmware setup it may be called TPM, fTPM, PTT or Security Device, and it must be on). The installer stops with an error without it.
- **Secure Boot turned off** in the firmware setup. Atos cannot yet set up its own Secure Boot keys during the install, so with Secure Boot on the installed system does not start. See [Turning Secure Boot off and on](secure-boot-off-and-on.md) for what that means for your disk.
- Paper and a pen for the recovery key.

The install needs no network and no account.

## Installing

1. Plug in the stick and start the computer from it (often F12, F8 or Esc opens the boot menu). Choose **Install Atos**.
2. After a short wait the screen lists the disks it can install to. Type the number of the disk and press Enter. The stick itself is not in the list.
3. Type `erase` and press Enter to confirm that this disk will be erased. Anything else cancels.
4. Type a password for the user `atos` and press Enter, then type it again. Nothing shows while you type. You log in with it and use it to make system changes.
5. The installer prepares the disk. It then shows a **recovery key**. Write it down exactly and keep it away from the computer. You need it if the firmware settings, the Secure Boot keys or the TPM change; without it nobody, not even you, can read the disk then. Press Enter once you have written it down.
6. The installer copies the system, which takes a few minutes. It then says that Atos is installed.
7. Press Enter. The computer restarts. Remove the USB stick while it restarts, so it starts Atos from the disk.
8. Atos starts at a login prompt. Type `atos`, press Enter, then type your password.

If you leave the stick in, the computer starts the installer again. Nothing happens to your disk: remove the stick and restart.

## If something goes wrong

The installer never restarts on its own. When a step fails it shows the error and asks you to press Enter to try again from the start, or to type `shell` for a command line (type `exit` to come back). If the computer has no TPM, or it is turned off, the installer notices only after it has erased the disk and shown a recovery key (that key is then useless). Turn the TPM on in the firmware setup and start the installer again.
