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

The C3 shell (`c3-shell.yml`, #65) also links PipeWire, so the runner needs its runtime library too: `sudo apt-get install -y --no-install-recommends libpipewire-0.3-0t64`. The job's check step fails without it (the shell does not start).

Binaries are built on GitHub-hosted runners, and the budget harness is a Rust program that needs only glibc and `/proc`. The measurements run inside a compositor on the GPU, which needs the packages in step 7 and the GPU access in [GPU access](#gpu-access-permanent-option-a).

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

## 7. Packages for the compositor and the D-006 measurements (#12)

[`.github/workflows/perf.yml`](../.github/workflows/perf.yml) measures inside a headless sway compositor. [`.github/workflows/d006-measure.yml`](../.github/workflows/d006-measure.yml) also starts the Files prototypes there, injects keys and reads their accessibility trees. That needs, once, as the owner:

```sh
sudo apt-get install -y --no-install-recommends sway wtype wl-clipboard grim at-spi2-core gir1.2-atspi-2.0 python3-gi dbus-daemon libgl1-mesa-dri libegl1 fontconfig fonts-dejavu-core mesa-utils
```

| Package | Why |
| --- | --- |
| `sway`, `wtype` | Headless compositor and key injection |
| `wl-clipboard`, `grim` | Clipboard check for *Copy Path*, screenshots of the walkthrough |
| `at-spi2-core`, `gir1.2-atspi-2.0`, `python3-gi` | AT-SPI bus and the tree dump |
| `libgl1-mesa-dri`, `libegl1`, `fontconfig`, `fonts-dejavu-core` | OpenGL ES through Mesa's software rasteriser (Slint's femtovg renderer) and a font |
| `dbus-daemon`, `mesa-utils` | A private session bus per run; `eglinfo`, to record which GL renderer (llvmpipe or a GPU driver) the apps get |

The `runner` user has no login session, so sway runs headless; with the GPU access below it renders with `gles2` on the GPU's render node. Both `perf.yml`'s `measure` job and the D-006 `measure-nuc` job (four variants: libcosmic default, libcosmic `wgpu`, Slint default, Slint software renderer) need that access and **fail at their check without it**. Run it with `gh workflow run d006-measure.yml -f nuc=true` or the label `d006-nuc` on a pull request; the job takes about 2 h 15 min (idle CPU over the full 5 minutes, 5 runs per variant). The job summary evaluates the gates G1–G5 of [`D-006-toolkit.md`](decisions/D-006-toolkit.md#41-the-gpu-gates-exact) per variant and marks a variant **not measured** unless both the compositor's Wayland `egl:` line and the app's own renderer line show the Intel driver.

## GPU access (permanent, option A)

Atos targets normal laptops and desktops that draw on the GPU, so the reference runner measures on the GPU too. The owner first set this up for the D-006 run (#36) and decided on 2026-11-06 to keep it for good (#44), for the nightly budgets and future GPU benchmarks. Without it, sway falls back to software rendering (pixman, llvmpipe), which no target machine uses.

The set-up gives the runner two things: membership of the group `render` and the Intel Vulkan driver. Do this once, while no job is running, since step 3 restarts the runner.

1. Check whether the Vulkan driver is already there. If `dpkg -s` prints `Status: install ok installed`, skip step 2.

   ```sh
   dpkg -s mesa-vulkan-drivers 2>/dev/null | grep '^Status' || echo "not installed"
   ```

2. Install the Intel Vulkan driver (for libcosmic's `wgpu` build). Note the "NEW packages" line apt prints, in case you remove it later.

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

**Why this is safe.** A render node (`/dev/dri/renderD*`) gives GPU rendering and compute only: no display, no mode setting, no input devices and no other user's screen. No service, port, sudo right or persistent setting is added. It stays safe only while all of these hold:

- Fork pull-request workflows stay disabled (**Settings** → **Actions** → **General**), and the workflows keep their own fork rule, so only code from branches of this repository reaches the NUC.
- The runner stays the unprivileged user `runner`: no password, not in `sudo`, no other groups than `runner` and `render` (plus the optional drop-caches rule below).
- No untrusted code runs on the NUC: nothing from forks, no downloads outside the pinned workflow actions and the build artifacts, no other services or secrets under `runner`.

**Every GPU job proves it.** `perf.yml` and `d006-measure.yml` record the GL renderer that sway's Wayland clients get (the `egl:` line) in the job summary. `perf.yml` fails rather than measure if that renderer is a software one (`llvmpipe`, `softpipe`) or missing, or if sway does not start on `gles2`.

**How to remove it** (back to software-only, for example before handing the NUC on):

```sh
sudo gpasswd -d runner render
sudo systemctl restart 'actions.runner.*'
ps -o user=,supgrp= -C Runner.Listener                    # runner  runner (no render)
sudo apt-get remove -y mesa-vulkan-drivers                # only if step 2 installed it
```

If step 2's "NEW packages" line listed more than `mesa-vulkan-drivers`, remove those too by name. Don't use `apt-get autoremove` blindly; it may remove packages that other steps installed. After removal, the GPU jobs in `perf.yml` and `d006-measure.yml` fail at their check until the access is back.

If a summary ever shows `llvmpipe` in the `egl:` line, headless sway did not hand the GPU to its clients; for the D-006 measurements, option B below runs sway on a real display instead.

### D-006 option B: a real display

As the owner, without touching the runner. Needs a monitor and keyboard on the NUC and no root.

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
- **Remove completely:** after the two blocks above, `sudo userdel -r runner` (this also ends its `render` membership) and, if it was added, `sudo rm /etc/sudoers.d/runner-drop-caches`.
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
- Without the rule nothing breaks: the workflow tries `sudo -n`, carries on, and the job summary says `Cold cache: no`. The failed `sudo -n` leaves a harmless failed-sudo entry in the NUC's log on every run.

## Security notes

- Jobs run code from branches of this repository only. `perf.yml` never runs for pull requests from forks; keep **Settings** → **Actions** → **General** → fork pull request workflows turned off. Together with the private repository this is the primary guard. If the repository ever goes public, remove the runner or require approval for all outside contributors first.
- Use the NUC for measurements only: no other secrets, keys or services under the `runner` user.
- Other load on the NUC skews the numbers. Avoid using it around the nightly run at 01:30 UTC (about 10 minutes).
- If the NUC is off, nightly jobs wait in the queue for up to 24 hours and then fail; nothing else is affected.
