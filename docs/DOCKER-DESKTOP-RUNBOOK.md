# Docker Desktop on a Mac — the runbook: what is installed, how it got there, resize it, upgrade it

Every command below was run on the 2019 Intel MacBook on 2026-09-14, with the output it gave; nothing is
recalled from memory. It exists because the lab's oldest "limitation" — the `6.6.12-linuxkit` kernel that
refused netkit — turned out to be a Docker Desktop **version** (4.27.2, February 2024), not the machine
(SETUP Step 2.1's note, gotcha #103), and finding that out took a sequence of questions worth keeping.
The order is the order to ask them in: what is running → what is configured → what the machine has →
how it was installed → change it → upgrade it → verify.

Everything here runs with Docker Desktop **quit** unless a step says otherwise. Docker Desktop reads
its settings file at start, so a change made while it runs is overwritten, and a change made while it
is quit is applied at the next start (SETUP Step 2.4's rule).

## 1. Is it running, and which version is installed

```bash
pgrep -fl 'Docker Desktop|Docker.app|com.docker' || echo "not running"
defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString
```

```text
not running
4.27.2
```

`defaults read` on the bundle's `Info.plist` is the version of the app on disk; `docker version` would
need the daemon up. The VM's kernel is only readable with Docker running:
`docker info --format '{{.KernelVersion}}'` (it said `6.6.12-linuxkit` on this version).

## 2. What the VM is configured with — the settings file

Docker Desktop 4.27 keeps its settings in `settings.json`; releases since about 4.35 write
`settings-store.json` beside it. Read whichever exists (the preflight does the same):

```bash
f="$HOME/Library/Group Containers/group.com.docker/settings.json"
ls -l "$f"
python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("cpus", "memoryMiB", "swapMiB", "diskSizeMiB", "kernelForUDP", "useVirtualizationFramework",
          "useVirtualizationFrameworkVirtioFS", "useVirtualizationFrameworkRosetta", "networkType",
          "autoStart", "dataFolder", "settingsVersion"):
    print(f"  {k:36} {d.get(k)!r}")
PY
```

```text
-rw-r--r--@ 1 olasumbo  staff  3536 Sep 10 15:13 .../group.com.docker/settings.json
  cpus                                 16
  memoryMiB                            16384
  swapMiB                              1024
  diskSizeMiB                          61035
  kernelForUDP                         True
  useVirtualizationFramework           True
  useVirtualizationFrameworkVirtioFS   True
  useVirtualizationFrameworkRosetta    False
  networkType                          'gvisor'
  autoStart                            False
  dataFolder                           '/Users/olasumbo/Library/Containers/com.docker.docker/Data/vms/0/data'
  settingsVersion                      35
```

The keys the lab depends on: `cpus` / `memoryMiB` (Step 2.3), `kernelForUDP` (Step 2.3b — the host
bridge that makes Step 3.5's route possible), `useVirtualizationFramework` (the VMM; on Apple silicon
the alternative is Docker VMM), `autoStart` (off here, on purpose — nothing restarts with the machine).

## 3. What the VM's disk and the host have

```bash
ls -lh "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" | awk '{print $5}'   # apparent
du -h  "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" | awk '{print $1}'   # on disk
/usr/sbin/sysctl -n hw.ncpu hw.memsize
```

```text
60G
48G
16
34359738368
```

`Docker.raw` is a sparse file: 60 GB apparent, 48 GB actually used by images, the kind nodes and
their volumes. The host has 16 CPUs and 32 GiB.

## 4. Change the allocation without the GUI — back up, edit, read back, diff

The operator's ask on 2026-09-14: 2 CPUs and 8 GB, nothing else touched.

```bash
f="$HOME/Library/Group Containers/group.com.docker/settings.json"
b="$f.before-4.27.2-shrink-2026-09-14"
cp -p "$f" "$b"
python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
before = (d["cpus"], d["memoryMiB"]); d["cpus"] = 2; d["memoryMiB"] = 8192
json.dump(d, open(p, "w"), indent=2); print(f"cpus/memoryMiB: {before} -> ({d['cpus']}, {d['memoryMiB']})")
PY
diff <(python3 -m json.tool "$b") <(python3 -m json.tool "$f")
```

```text
cpus/memoryMiB: (16, 16384) -> (2, 8192)
14c14
<     "cpus": 16,
---
>     "cpus": 2,
61c61
<     "memoryMiB": 16384,
---
>     "memoryMiB": 8192,
```

The diff is the proof that only two values changed. The backup stays beside the file, named by what it
was and when. On a version that writes `settings-store.json`, the same edit goes into that file — the
key names differ (read the file first, change only what you read).

The GUI path is Settings → Resources → Advanced, then Apply & restart; it writes the same file.

## 5. How it was installed — brew cask, a dmg, or the App Store

Docker Desktop is not on the Mac App Store, so the answer is Homebrew or a downloaded dmg; the
difference decides how it is upgraded.

```bash
brew list --cask | grep -i docker                                   # a cask name = Homebrew
brew info --cask docker-desktop | sed -n 1,4p                        # installed vs latest
ls -la /usr/local/Caskroom/ | grep -i docker                         # the Caskroom entries
ls /Applications/Docker.app/Contents/_MASReceipt 2>/dev/null || echo "no App Store receipt"
mdls -name kMDItemWhereFroms /Applications/Docker.app                # a download URL = dragged from a dmg
ls -ld /Applications/Docker.app                                      # owner and date
```

```text
docker
docker-desktop
==> docker-desktop (Docker Desktop, Docker Community Edition, Docker CE): 4.27.2,137060 → 4.90.0,238679 (auto_updates)
App to build and share containerised applications and microservices
https://www.docker.com/products/docker-desktop
Installed (as dependency)
lrwxr-xr-x  docker -> docker-desktop
drwxr-xr-x  docker-desktop
no App Store receipt
kMDItemWhereFroms = (null)
drwxr-xr-x@ 3 olasumbo  staff  96 Feb  8  2024 /Applications/Docker.app
```

Reading: Homebrew installed it, as the cask `docker-desktop` (the `docker` entry is a symlink — the
cask was renamed, and Homebrew left the old name pointing at the new); the installed cask version is
4.27.2 and the latest is 4.90.0; no App Store receipt; no download URL on the bundle (a dmg dragged in
through the Finder would carry one). So the upgrade path is the cask.

What the cask will run, read before running it:

```bash
brew cat --cask docker-desktop | grep -nE 'sudo|postflight|uninstall|launchctl'
```

The cask's `postflight` only symlinks `kubectl` when `/usr/local/bin/kubectl` does not exist (it does
here — Homebrew's `kubernetes-cli`), and its `uninstall` stanza removes the previous version's launchd
services and privileged helpers with `sudo: if_needed`.

## 6. Upgrade through the cask — and where it needs a terminal

```bash
HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask docker-desktop
```

```text
==> Would upgrade 1 requested outdated package
docker-desktop 4.27.2,137060 -> 4.90.0,238679
==> Fetching downloads for: docker-desktop
✔︎ Cask docker-desktop (4.90.0,238679)
==> Upgrading docker-desktop
==> Removing launchctl service com.docker.helper
==> Removing launchctl service com.docker.socket
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
==> Removing launchctl service com.docker.vmnetd
sudo: a password is required
==> Removing files:
/Library/PrivilegedHelperTools/com.docker.socket
Error: docker-desktop: Failure while executing; `/usr/bin/sudo -E -- /usr/bin/xargs -0 -- /bin/rm -r -f --` exited with 1.
==> Purging files for version 4.90.0,238679 of Cask docker-desktop
```

What happened, measured afterwards: the 641 MB image was downloaded and is cached
(`~/Library/Caches/Homebrew/downloads/*--Docker.dmg`); the app on disk is still 4.27.2; the cask's
uninstall step needs a password to remove the root-owned helpers under `/Library/PrivilegedHelperTools`
and their LaunchDaemons, and it cannot ask for one from a non-interactive shell. The one user-level
service, `com.docker.helper`, was removed — Docker Desktop recreates it at launch. Nothing else changed.

So the command is run in a terminal where `sudo` can prompt; the download is not repeated:

```bash
brew upgrade --cask docker-desktop
```

`HOMEBREW_NO_AUTO_UPDATE=1` only skips the `brew update` that would otherwise precede it; leave it out
if the cask index may be stale.

**If it had been a dmg install instead** — no cask to upgrade — Docker's documented command line is:

```bash
curl -L -o Docker.dmg https://desktop.docker.com/mac/main/amd64/Docker.dmg   # arm64/ for Apple silicon
sudo hdiutil attach Docker.dmg
sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --accept-license --user="$USER"
sudo hdiutil detach /Volumes/Docker
```

(the commands and the two download URLs are Docker's own [install page](https://docs.docker.com/desktop/setup/install/mac-install/):
`--accept-license` accepts the subscription agreement up front, `--user` "performs the privileged
configurations once during installation"; the same helpers need root either way. The GUI route is
drag-to-Applications, then the agreement and the password prompt at first launch.)

## 7. Verify after the upgrade

With Docker Desktop launched once (it reinstalls its privileged helpers, asks for the password in the
GUI, and migrates `settings.json` into `settings-store.json` on a version that uses it):

```bash
defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString   # 4.90.0
ls /usr/local/Caskroom/docker-desktop/                                                  # the new version's directory
docker info --format 'CPUs={{.NCPU}} Mem={{.MemTotal}} Kernel={{.KernelVersion}}'         # 2 / 8 GiB / the new kernel
python3 -c 'import json,glob; [print(f, {k:v for k,v in json.load(open(f)).items() if any(s in k.lower() for s in ("cpu","memory","kernelforudp","vmtype","virtualization"))}) for f in glob.glob("'"$HOME"'/Library/Group Containers/group.com.docker/settings*.json")]'
scripts/lab-preflight.sh                                                                 # the table: netkit, Tetragon's symbol, the host bridge, IPv6
```

The preflight is the acceptance test: `route to the LB blocks` should name the VM's `eth1` address (kernelForUDP
survived the migration), and `Tetragon base sensor` says whether demo 17 can run on this kernel. If `kernelForUDP`
did not survive, Step 2.3b puts it back. `netkit (kernel 7.0.12-linuxkit)` reads **no** on this kernel, and that is
correct: 4.91.0's linuxkit kernel is built without `CONFIG_NETKIT` (measured on the M5, 2026-09-15 — gotcha #109);
an earlier version of this paragraph expected "a netkit device was created" from the version alone. On a Desktop
installed fresh the settings file is `settings-store.json` with PascalCase keys and the three the lab needs absent by
default — `scripts/bootstrap/macos.sh` handles both files (gotcha #108).

## The numbers from this machine, for the record

| | Before (2026-09-14, 06:30) | After the shrink | After the upgrade |
|---|---|---|---|
| Docker Desktop | 4.27.2 (cask, installed 2025-07-29 under this name) | 4.27.2 | 4.90.0 once the terminal run completes |
| VM CPUs / memory | 16 / 16384 MiB | **2 / 8192 MiB** | unchanged by the upgrade (verify in §7) |
| VM disk | 61035 MiB, `Docker.raw` 48 GB on disk | unchanged | unchanged |
| kernel | 6.6.12-linuxkit | unchanged | 7.0.x (4.89.0 release notes: v7.0.12) — measured by the preflight |
| kernelForUDP | on | on | verify |
