# Reference runner (Intel NUC 11)

How the owner registers the reference hardware from [`spec.md` §7](spec.md#7-quality-budgets) as a self-hosted GitHub Actions runner for [`.github/workflows/perf.yml`](../.github/workflows/perf.yml). Agents never do this; they have no access to the NUC.

- Machine: Intel NUC 11, Celeron N5105, x86_64, Ubuntu Server 24.04.5 LTS (minimal, no desktop).
- The runner runs as a dedicated unprivileged user `runner`, as a systemd service, with the labels `self-hosted` and `nuc`.
- It connects out to github.com over HTTPS and waits for jobs. No inbound port is opened.
- Runner version: **2.338.2** (released 2026-10-26).

Every step below is run by the owner on the NUC, logged in as their own user. Lines with `sudo` ask for the owner's password.

## 1. Install packages

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends curl ca-certificates libicu74 libkrb5-3 liblttng-ust1t64 libssl3t64 zlib1g
```

| Package | Why |
| --- | --- |
| `curl`, `ca-certificates` | Download the runner over HTTPS (step 3) |
| `libicu74`, `libkrb5-3`, `liblttng-ust1t64`, `libssl3t64`, `zlib1g` | Libraries the runner (.NET) needs. The same list the runner's own `bin/installdependencies.sh` installs on Ubuntu 24.04, so that script never has to run as root |

The measurements need nothing else today: binaries are built on GitHub-hosted runners, and the budget harness is a Rust program that needs only glibc and `/proc`. Packages for later measurements (for example sway for the D-006 prototypes, #12) are added by those cards.

## 2. Create the runner user

```sh
sudo useradd --create-home --shell /bin/bash runner
id runner
```

`id` should list only the group `runner`. The user has no password (it cannot log in with one) and is not in the `sudo` group.

## 3. Download the runner

Switch to the runner user for steps 3 and 4:

```sh
sudo -iu runner
```

Then, as `runner`:

```sh
mkdir actions-runner && cd actions-runner
curl -fsSLO https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
echo "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40  actions-runner-linux-x64-2.338.2.tar.gz" | sha256sum --check
tar xzf actions-runner-linux-x64-2.338.2.tar.gz && rm actions-runner-linux-x64-2.338.2.tar.gz
```

`sha256sum` must print `OK`. If it does not, stop and do not run anything from the archive. The checksum is the one in the [v2.338.2 release notes](https://github.com/actions/runner/releases/tag/v2.338.2), matching the digest GitHub shows for the asset.

## 4. Register the runner

1. On github.com, open the repository → **Settings** → **Actions** → **Runners** → **New self-hosted runner** (direct link: <https://github.com/jens-thomae/Atos/settings/actions/runners/new>). Choose **Linux**, **x64**.
2. Copy only the token from the `./config.sh --url … --token <TOKEN>` line. It is valid for one hour. Ignore the page's download commands; step 3 did that.
3. Still as `runner`, in `~/actions-runner`:

```sh
./config.sh --unattended --url https://github.com/jens-thomae/Atos --name nuc --labels nuc --token <TOKEN>
exit
```

The runner adds the default labels `self-hosted`, `Linux` and `X64` itself, so it ends up with `self-hosted`, `Linux`, `X64`, `nuc`. `exit` returns to the owner's user.

## 5. Install the service

As the owner:

```sh
sudo bash -c 'cd /home/runner/actions-runner && ./svc.sh install runner && ./svc.sh start && ./svc.sh status'
```

`svc.sh` must run as root from the runner directory. The `cd` is inside the root command because `/home/runner` is readable only by `runner` (Ubuntu's default home mode 750). No root account or runner password is needed.

`install runner` creates a systemd unit named `actions.runner.<owner>-<repo>.nuc.service`, which runs the runner as the user `runner`, starts at boot and restarts it if it stops. `status` should show `active (running)`.

## 6. Verify

1. **Settings** → **Actions** → **Runners** shows `nuc` as **Idle**, with the labels `self-hosted`, `Linux`, `X64`, `nuc`.
2. On the NUC: `systemctl status 'actions.runner.*'` shows `active (running)`, and `ps -o user= -C Runner.Listener` prints `runner`.
3. Comment on #17 that the runner is online. An agent then adds the `perf` label to the open pull request for one on-demand run, and the next nightly run (01:30 UTC) shows up under **Actions** → **Perf**.

## 7. Packages for the D-006 measurements (#12)

[`.github/workflows/d006-measure.yml`](../.github/workflows/d006-measure.yml) starts the Files prototypes in a headless sway compositor, injects keys and reads their accessibility trees. That needs, once, as the owner:

```sh
sudo apt-get install -y --no-install-recommends sway wtype wl-clipboard grim at-spi2-core gir1.2-atspi-2.0 python3-gi dbus-daemon libgl1-mesa-dri libegl1 fontconfig fonts-dejavu-core mesa-utils
```

| Package | Why |
| --- | --- |
| `sway`, `wtype` | Headless compositor (pixman software renderer) and key injection |
| `wl-clipboard`, `grim` | Clipboard check for *Copy Path*, screenshots of the walkthrough |
| `at-spi2-core`, `gir1.2-atspi-2.0`, `python3-gi` | AT-SPI bus and the tree dump |
| `libgl1-mesa-dri`, `libegl1`, `fontconfig`, `fonts-dejavu-core` | OpenGL ES through Mesa's software rasteriser (Slint's femtovg renderer) and a font |
| `dbus-daemon`, `mesa-utils` | A private session bus per run; `eglinfo`, to record which GL renderer (llvmpipe or a GPU driver) the apps get |

Without the GPU steps below the `runner` user has no login session, so sway could only run headless with the software renderer. The `measure-nuc` job now measures on the GPU (sway `gles2` on `/dev/dri/renderD128`, four variants: libcosmic default, libcosmic `wgpu`, Slint default, Slint software renderer) and **fails at its package check until the owner has done option A below**. Run it with `gh workflow run d006-measure.yml -f nuc=true` or the label `d006-nuc` on a pull request; the job takes about 2 h 15 min (idle CPU over the full 5 minutes, 5 runs per variant). The job summary evaluates the gates G1–G5 of [`D-006-toolkit.md`](decisions/D-006-toolkit.md#41-the-gpu-gates-exact) per variant and marks a variant **not measured** unless both the compositor's Wayland `egl:` line and the app's own renderer line show the Intel driver.

## GPU measurements (D-006, #36)

Owner steps, once the card #36 is merged and before the run. Do this while no job is running, since step 3 restarts the runner. Everything is undone afterwards.

**Option A (recommended): give the runner the render node.**

1. Check whether the Vulkan driver is already there. If `dpkg -s` prints `Status: install ok installed`, skip step 2 and the last line of the undo.

   ```sh
   dpkg -s mesa-vulkan-drivers 2>/dev/null | grep '^Status' || echo "not installed"
   ```

2. Install the Intel Vulkan driver (for libcosmic's `wgpu` build). Note the "NEW packages" line apt prints, for the undo.

   ```sh
   sudo apt-get install -y --no-install-recommends mesa-vulkan-drivers
   ```

3. Let the runner open the GPU's render node, and restart the runner so it picks this up:

   ```sh
   sudo usermod -aG render runner
   sudo systemctl restart 'actions.runner.*'
   ```

4. Check:

   ```sh
   ls -l /dev/dri/renderD128                       # crw-rw---- root render
   ps -o user=,supgrp= -C Runner.Listener          # runner  runner,render
   ```

This changes one group membership (render nodes allow GPU rendering and compute only, not display or input) and one driver package. No service, port, sudo right or persistent setting is added. Then start the run (above).

**Undo**, after the run:

```sh
sudo gpasswd -d runner render
sudo systemctl restart 'actions.runner.*'
ps -o user=,supgrp= -C Runner.Listener                    # runner  runner (no render)
sudo apt-get remove -y mesa-vulkan-drivers                # only if step 2 installed it
```

If step 2's "NEW packages" line listed more than `mesa-vulkan-drivers`, remove those too by name. Don't use `apt-get autoremove` blindly; it may remove packages that other steps installed.

If the summary says the `egl:` line is still `llvmpipe` (headless sway did not hand the GPU to its clients; that wlroots picks the render node in headless mode is expected but **unverified on the NUC**), use option B.

**Option B (fallback): a real display, as the owner, without touching the runner.** Needs a monitor and keyboard on the NUC and no root.

1. On another machine, download the `d006-bundle` artifact of a workflow run (the hosted `build` job) from the run page; GitHub delivers it as a zip. Copy it to the NUC as `~/d006-bundle.zip`.
2. Log in on the console (tty1) as the owner, so logind gives sway a seat. Unpack and start sway with [`tools/d006/sway-drm.conf`](../tools/d006/sway-drm.conf):

   ```sh
   mkdir ~/d006 && python3 -m zipfile -e ~/d006-bundle.zip ~/d006 && cd ~/d006 && chmod +x bin/* tools/d006/* && sway -c tools/d006/sway-drm.conf
   ```

   (`python3 -m zipfile` is used because `unzip` may not be installed; the `chmod` restores the executable bits it drops.) The config runs `D006_COMPOSITOR=existing D006_RENDERER=gles2 tools/d006/measure.sh bin out-gpu` inside that sway and then `swaymsg exit`.
3. Leave the machine alone until sway exits by itself (about 2 h 15 min). Then summarize and copy off the results:

   ```sh
   python3 tools/d006/summarize.py out-gpu > out-gpu/summary.md
   ```

**Undo:** `rm -rf ~/d006 ~/d006-bundle.zip`. Nothing else changed.

## Updates

The runner updates itself when GitHub releases a new version (its default; GitHub stops sending jobs to runners that fall too far behind). The pinned version and checksum above cover the first install. Ubuntu updates are the owner's as usual; a kernel update changes measurements, and the job summary records the kernel for that reason.

## Remove or re-register

As the owner:

```sh
sudo bash -c 'cd /home/runner/actions-runner && ./svc.sh stop && ./svc.sh uninstall'
```

Get a removal token: **Settings** → **Actions** → **Runners** → `nuc` → **Remove** → copy the token from the Linux command. Then:

```sh
sudo -iu runner bash -c 'cd ~/actions-runner && ./config.sh remove --token <TOKEN>'
```

- **Re-register** (new name, moved machine, broken registration): get a new registration token and repeat steps 4 and 5. Step 3 is only needed for a fresh directory.
- **Remove completely:** after the two blocks above, `sudo userdel -r runner` and, if it was added, `sudo rm /etc/sudoers.d/runner-drop-caches`.
- If the NUC is gone for good and cannot run `config.sh remove`, delete the runner on the same Settings page (**Remove** → **Force remove this runner**).

## Optional: true cold start (decision for the owner)

The cold-start budget means starting an app whose files are not in the page cache. The binaries arrive on the NUC just before the measurement, so they are still cached, and the result is a warm start. Emptying the cache needs root (`vm.drop_caches`), which the runner user does not have.

**Proposal:** allow the runner user exactly one root command, with exactly these arguments, and nothing else:

```sh
echo 'runner ALL=(root) NOPASSWD: /usr/sbin/sysctl -q -w vm.drop_caches=3' | sudo tee /etc/sudoers.d/runner-drop-caches
sudo chmod 0440 /etc/sudoers.d/runner-drop-caches
sudo visudo -cf /etc/sudoers.d/runner-drop-caches
sudo -u runner sudo -n /usr/sbin/sysctl -q -w vm.drop_caches=3 && echo allowed
```

`visudo -c` must report `parsed OK`, and the last line must print `allowed`.

- Effect: the kernel drops clean cached file data. No data is lost; the machine is briefly slower while caches refill.
- Risk: anyone who can push a branch and label a pull request `perf` can trigger it. Worst case is a slower NUC, not access to anything.
- Without the rule nothing breaks: the workflow tries `sudo -n`, carries on, and the job summary says `Cold cache: no`.

## Security notes

- Jobs run code from branches of this repository only. `perf.yml` never runs for pull requests from forks; keep **Settings** → **Actions** → **General** → fork pull request workflows turned off as a second guard.
- Use the NUC for measurements only: no other secrets, keys or services under the `runner` user.
- Other load on the NUC skews the numbers. Avoid using it around the nightly run at 01:30 UTC (about 10 minutes).
- If the NUC is off, nightly jobs wait in the queue for up to 24 hours and then fail; nothing else is affected.
