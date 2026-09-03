# CyberMyth OS — amd64 live ISO

Build tree for `cybermyth-1.0-amd64.iso`: a UEFI x64 live ISO with a GRUB menu,
the GNOME desktop and the Calamares installer, on a Debian 13 (trixie) base with
a custom `6.18.49-cybermyth-amd64` kernel.

CyberMyth is an offensive-security distribution with Tails-style anonymity
features. This tree builds the **amd64** image; the arm64 Surface Pro 12 image
lives in `../SP12`.

> **`build.md` explains *why* every decision in this pipeline was made** — the
> no-backports policy, the firmware/kernel version drift, the arch split, the
> Calamares overrides. Read it before changing anything. This file is only the
> *how*.

---

## Prerequisites

Debian 13 amd64 host. Install the build dependencies:

```bash
sudo apt install -y \
  build-essential debhelper bc bison flex libelf-dev libssl-dev dwarves \
  rsync kmod cpio fakeroot dpkg-dev zstd \
  debootstrap imagemagick libglib2.0-bin libglib2.0-dev-bin unzip \
  xorriso squashfs-tools grub-efi-amd64-bin dosfstools mtools \
  curl gnupg
```

You also need:

- **~60 GB free disk.** The kernel object tree alone is 32 GB (BTF forces full
  DWARF), plus ~6 GB rootfs, 2.4 GB ISO and 1.8 GB of packages.
- **SSH access to the package repo** at `192.168.0.182`, key at
  `/home/ice/cybermyth/repo/ssh/repo_key`, and the **reprepro GPG signing
  passphrase** — the repo is configured with `ask-passphrase`, so pushes cannot
  run unattended.
- **`sudo`.** `mk-rootfs.sh` and `mk-iso.sh` need root. Everything else runs
  unprivileged.

Fetch the kernel source (not tracked in git — 32 GB once built):

```bash
cd /home/ice/cybermyth/Cybermyth-Linux
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.49.tar.xz
tar -xf linux-6.18.49.tar.xz && rm linux-6.18.49.tar.xz
```

---

## Full pipeline, in order

Every step is idempotent and safe to re-run. Steps 1–5 are unprivileged.

### 1. Kernel → `pkg/linux-*.deb`

```bash
./kernel/build-kernel.sh
```

Takes about **40 minutes** on 22 cores. Builds `linux-image-` and
`linux-headers-6.18.49-cybermyth-amd64` (plus a `-dbg` and `linux-libc-dev`
that are **not** shipped on the ISO).

It verifies **40 config expectations** and refuses to build if any is unmet,
because `merge_config.sh` only *warns* on conflicts and `olddefconfig` silently
drops symbols whose dependencies are unmet — neither shows up until the finished
kernel is missing a driver.

```bash
./kernel/build-kernel.sh --config-only   # generate + verify .config, don't compile
./kernel/build-kernel.sh --reconfig      # regenerate .config from scratch, then build
```

### 2. Tor Browser → `pkg/tor-browser_*_amd64.deb`

```bash
./pkg/build-tor-browser.sh
```

Downloads the official stable `linux-x86_64` build, verifies it against a pinned
SHA-256 **and** the Tor Project's OpenPGP key `EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`
fetched over WKD, then packages it. `cybermyth-desktop` depends on
`tor-browser`, so without this the rootfs build cannot resolve.

### 3. Firmware → `pkg/firmware/`

```bash
./pkg/fetch-firmware.sh --list   # show what would be fetched
./pkg/fetch-firmware.sh          # download + verify (26 packages, 307 MB)
```

**This is what makes Wi-Fi work.** Debian 13 ships firmware `20250410`, built
for Debian's 6.12 kernel; our 6.18 kernel requires iwlwifi firmware API ≥ 100
and trixie tops out at 97, so Intel Wi-Fi 7 has **no Wi-Fi at all** (Bluetooth
still works, which makes it easy to miss). The script asserts an API ≥ 100 file
is actually present before it exits successfully.

### 4. Arch-split the colliding firmware metapackages → `pkg/firmware-arch/`

```bash
./pkg/rearch-firmware.sh
```

Two different packages are both called `firmware-linux` — CyberMyth's arm64 one
and Debian's — and both were `Architecture: all`, so each appeared in *both*
indices. This rebuilds them as `arm64` and `amd64` respectively.

### 5. Push to the repo — **needs the signing passphrase**

```bash
./pkg/push-to-repo.sh --dry-run
./pkg/push-to-repo.sh        # tor-browser, cybermyth-desktop, cybermyth-sp12, gnome-backgrounds

./pkg/push-firmware.sh --dry-run
./pkg/push-firmware.sh       # the firmware set; prompts YES, then the passphrase
```

`push-firmware.sh` contains **the only destructive step in the whole build**: it
must `reprepro remove` the old `arch:all` firmware entries before re-adding them
arch-split, because reprepro will not swap an `arch:all` entry for arch-specific
ones. It prints exactly what it removes and requires you to type `YES`.

Both scripts verify the published index over HTTPS afterwards — including that
arm64 **still** gets its own `*cybermyth*` metapackage, so a mistake here cannot
quietly break SP12.

### 6. Root filesystem — **needs root**

```bash
sudo ./mk-rootfs.sh
```

Roughly **30–45 minutes**. Resumable: each expensive stage records itself in
`rootfs.state`, so a failure in branding does not repeat `debootstrap`.

```bash
sudo ./mk-rootfs.sh --fresh   # delete rootfs/ and start over
```

Start fresh whenever repo packages changed, or the build will happily reuse the
old ones.

### 7. ISO — **needs root**

```bash
sudo ./mk-iso.sh
```

Produces `cybermyth-1.0-amd64.iso` plus a `.sha256` sidecar. The squashfs is
only rebuilt when `rootfs/` is newer, so re-running after a `grub.cfg` tweak
takes seconds.

```bash
sudo ./mk-iso.sh --clean      # remove iso-work/ and exit
```

### 8. Write to a USB stick

```bash
sudo dd if=cybermyth-1.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Check the target with `lsblk` first. **Secure Boot must be disabled** — the
kernel is signed by a build-generated key that is in no firmware db.

---

## From nothing to an ISO

```bash
cd /home/ice/cybermyth/Cybermyth-Linux

curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.49.tar.xz
tar -xf linux-6.18.49.tar.xz && rm linux-6.18.49.tar.xz

./kernel/build-kernel.sh
./pkg/build-tor-browser.sh
./pkg/fetch-firmware.sh
./pkg/rearch-firmware.sh
./pkg/push-to-repo.sh
./pkg/push-firmware.sh

sudo ./mk-rootfs.sh --fresh
sudo ./mk-iso.sh
```

## Rebuilding after a change

| Changed | Run |
|---|---|
| a kernel fragment | `./kernel/build-kernel.sh --reconfig`, then from step 6 |
| a repo metapackage | `./pkg/push-to-repo.sh`, then `sudo ./mk-rootfs.sh --fresh` |
| branding / Calamares | `sudo ./mk-rootfs.sh` (branding stages are not cached), then step 7 |
| `grub.cfg` or menu entries | `sudo ./mk-iso.sh` only |

---

## The live session

| | |
|---|---|
| user | `cybermyth` |
| password | `cybermyth` |
| hostname | `cybermyth` |

The user is created **at boot by live-config**, not baked into the squashfs.
Override from the GRUB command line with `username=... hostname=...`.

GRUB offers **Live** (default), **Install CyberMyth OS** (launches Calamares
automatically) and **Live (safe graphics)**.

---

## Layout

```
kernel/          build-kernel.sh, the three config fragments, and the generated
                 config-cybermyth-amd64 (tracked — it is the reviewable artefact)
pkg/             package build/fetch/push scripts; the .debs they produce are
                 gitignored and regenerable
branding/        logos, wallpaper, motd, the GNOME Shell extension
calamares/       CyberMyth branding + the settings/module overrides layered over
                 calamares-settings-debian
keyring/         the public CyberMyth archive keyring
mk-rootfs.sh     debootstrap → apt → CyberMyth packages → kernel → branding
mk-iso.sh        squashfs → GRUB → BOOTX64.EFI → hybrid ISO
build.md         why every decision was made — read this before changing things
kali.config      Kali's kernel config, kept as the provenance for the wireless delta
```

Not in git (all regenerable): `linux-6.18.49/`, `rootfs/`, `iso-work/`, `*.iso`,
`*.deb`, `pkg/firmware*/`.

---

## If something fails

The scripts fail loudly and say what to do. A few that have actually bitten:

- **No Wi-Fi on Intel, Bluetooth fine** — the firmware is older than the kernel
  needs. Steps 3–5, then rebuild. `mk-rootfs.sh` asserts this now.
- **`no suitable firmware found` for anything else** — same class of problem;
  check the driver's `UCODE_API_MIN` against what Debian ships.
- **`cybermyth-desktop` will not install** — `tor-browser` is missing from the
  repo's amd64 index. Steps 2 and 5.
- **`rootfs exists but rootfs.state does not`** — leftovers from an older
  attempt. Use `--fresh`.
- **ISO boots as a virtual CD but not from USB** — the GPT is missing an EFI
  System partition. `mk-iso.sh` checks for this explicitly and fails.
