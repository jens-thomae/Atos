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
