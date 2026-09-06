# Building the CyberMyth OS amd64 live ISO

Produces `cybermyth-1.0-amd64.iso` — a UEFI x64 live ISO with a GRUB menu, the
GNOME desktop, and Calamares, on a Debian 13 (trixie) base with a custom
`6.18.49-cybermyth-amd64` kernel.

> This file replaces an earlier `build.md` written for the abandoned 6.18.40
> attempt. Nothing from that document carries over.

| | |
|---|---|
| Base | Debian 13 trixie, amd64 |
| Kernel | `6.18.49-cybermyth-amd64` |
| Desktop | GNOME (via `cybermyth-desktop`) |
| Installer | Calamares 3.3.14 |
| Boot | UEFI x64 only — **Secure Boot must be disabled** |
| Output | `cybermyth-1.0-amd64.iso` |

## Order of operations

```
kernel/build-kernel.sh      # unprivileged   -> pkg/linux-*.deb
pkg/build-tor-browser.sh    # unprivileged   -> pkg/tor-browser_*_amd64.deb
pkg/push-to-repo.sh         # needs the repo signing passphrase
sudo ./mk-rootfs.sh         # needs root     -> rootfs/
sudo ./mk-iso.sh            # needs root     -> cybermyth-1.0-amd64.iso
```

The two `mk-*` scripts are resumable: each expensive stage records itself in
`rootfs.state`, so a failure in branding does not repeat `debootstrap`. Pass
`--fresh` to start over.

## Decisions this build rests on

These are choices, not defaults. Changing one means changing the scripts.

### No backports, anywhere

`sources.list` has no backports entry, nothing is installed with `-t`, and
`/etc/apt/preferences.d/no-backports` pins `trixie-backports` to `-1` so the
policy survives someone adding the source by hand.

This required two upstream fixes:

- **`cybermyth-desktop` 1.0.2** pinned `mesa-* (>= 26.1.2-1~bpo13+1)`, which
  exists only in trixie-backports. That was a Surface Pro 12 Adreno X1-45 fix
  and made the metapackage unresolvable on amd64. **1.0.3** drops those pins;
  **`cybermyth-sp12` 1.0.5** picks them up, along with a backports source scoped
  to ALSA/PipeWire/libcamera on arm64 only.
- **Calamares' `sources-final` helper** from `calamares-settings-debian`
  rewrites the *installed* system's `/etc/apt/sources.list` and enables
  `trixie-backports` (and drops `contrib`/`non-free`). `calamares/helpers/`
  carries a CyberMyth replacement, installed over a `dpkg-divert` so an upgrade
  of that package cannot restore Debian's.

### Firmware comes from Debian

The CyberMyth repo ships its own `firmware-linux` (`20260810-cybermyth1`,
arch `all`, so it *does* appear in the amd64 index) and `linux-firmware-extra`.
Both are arm64-shaped and both are pinned to `-1` on amd64:

- `firmware-linux` deliberately **omits desktop GPU microcode** — it exists to
  keep ~275 MB of amdgpu/i915/nvidia blobs off a Surface tablet. On amd64 that
  is exactly the firmware we need.
- `linux-firmware-extra` — **122 of its 164 files collide** with Debian's
  `firmware-misc-nonfree`, `firmware-realtek`, `firmware-brcm80211`,
  `firmware-mediatek`, `firmware-siano` and `firmware-libertas`, and it declares
  no `Replaces`, so dpkg would refuse to unpack it. Its "zero collisions" was
  measured against an arm64 rootfs where none of those were installed. Of the 42
  non-colliding files, `ath9k_htc` and `carl9170` are already in Debian **main**
  (`firmware-ath9k-htc`, `firmware-carl9170`); the only real loss is four newer
  `rtw89` blobs.

`mk-rootfs.sh` fails the build if `firmware-linux`'s installed version contains
`cybermyth`, rather than trusting the arch split to have worked.

### The firmware must be newer than Debian 13's

**This is the single most important thing to know about this build.** Debian 13
ships firmware `20250410`, built for Debian's **6.12** kernel. CyberMyth runs
**6.18**, and 6.18 raised iwlwifi's minimum firmware API:

```
drivers/net/wireless/intel/iwlwifi/cfg/bz.c
#define IWL_BZ_UCODE_API_MIN  100
```

Intel Wi-Fi 7 (PCI `8086:272b` → `iwl_gl_mac_cfg` → BZ family) loads
`iwlwifi-gl-c0-fm-c0-<API>.ucode`. Trixie ships 92/94/96/97 — all below 100 — so
the device never initialises and there is **no Wi-Fi at all**. The first ISO
shipped this way. It is easy to miss because *every package installs
successfully* and **Bluetooth still works** (`btintel` is a separate driver with
no such floor).

`linux-firmware 20260810` ships API 100 and 101 and fixes it. `pkg/fetch-firmware.sh`
downloads that set from Debian unstable, checksum-verified, and asserts the
API ≥ 100 file is actually present before it will exit successfully.

`mk-rootfs.sh` then re-checks in the built rootfs — asserting the *file*, not the
package version, because "firmware-iwlwifi is installed" was true the whole time
the Wi-Fi was broken.

CPU microcode (`intel-microcode`, `amd64-microcode`) is deliberately **not**
bumped: it has no kernel API coupling, and Debian's security team maintains it
actively in trixie.

### Why the two firmware-linux packages are arch-split

The CyberMyth repo carries its own `firmware-linux` for arm64, which
deliberately omits desktop GPU microcode. Both it and Debian's were built
`Architecture: all`, so each appeared in *both* indices under the same name —
and dpkg sorts them the wrong way round:

```
dpkg --compare-versions 20260810-1 lt 20260810-cybermyth1   -> true
```

reprepro would have refused Debian's as a downgrade, and forcing it would have
pushed ~275 MB of amdgpu/i915/nvidia blobs onto every Surface Pro 12.
`pkg/rearch-firmware.sh` rebuilds them as `Architecture: arm64` (CyberMyth's,
bumped to `20260810-cybermyth2`) and `Architecture: amd64` (Debian's), so
neither is visible to the other's clients.

That fix **removed the need for an apt pin** rather than working around it —
verified by simulating the full firmware install with no preferences file at
all. An earlier attempt did use a pin, written `Pin: version *cybermyth*`, which
silently did nothing: APT's version pinning only supports a **trailing**
wildcard.

### Minimal package list

`cybermyth-core` and `cybermyth-desktop` *are* the product definition.
`mk-rootfs.sh` installs only what they do not already pull:

- live/installer infrastructure (`live-boot`, `live-config`, `user-setup`,
  `calamares`)
- boot plumbing (`grub-efi-amd64`, `parted`, `cryptsetup`, filesystem tools)
- the Debian firmware set and CPU microcode
- hardware basics (`network-manager`, `bluez`, `iw`, `wpasupplicant`, …)
- `nmap`

**To add a tool to the OS, add it to the metapackage in the repo — not to
`mk-rootfs.sh`.** That is what gives existing installs the tool on `apt upgrade`.

## Kernel

`kernel/build-kernel.sh` runs unprivileged (`bindeb-pkg` uses fakeroot) and
produces `linux-image-` and `linux-headers-6.18.49-cybermyth-amd64` in `pkg/`.
The `-dbg` and `linux-libc-dev` packages are built but deliberately **not** put
on the ISO.

Config lineage:

1. **Debian 13's own amd64 config from `/boot`** — the "compatible like Debian
   13" guarantee. Debian 13 ships a 6.12 kernel, so `olddefconfig` resolves the
   6.12 → 6.18 drift with upstream defaults, exactly as Debian does on a rebase.
2. `cybermyth-wireless.fragment`
3. `cybermyth-hardening.fragment`
4. `cybermyth-brand.fragment`

The script then **verifies all 40 expectations explicitly** and refuses to build
if any is unmet — `merge_config.sh` only warns on conflicts and `olddefconfig`
silently drops symbols whose dependencies are unmet, neither of which shows up
until a finished kernel is missing a driver.

### Wireless additions

Derived by diffing `kali.config` against Debian 13's config. The delta is not a
matter of taste: **Debian 13 ships 6.12 and these drivers landed afterwards.**

| Symbol | Hardware |
|---|---|
| `RTW88_8812AU` | RTL8812AU — Alfa AWUS036ACH |
| `RTW88_8814AU`, `RTW88_8814AE` | RTL8814AU — Alfa AWUS1900 |
| `RTW88_8821AU` | RTL8821AU / RTL8811AU |
| `RTW89_8851BU`, `RTW89_8852BU` | Wi-Fi 6 USB (`RTW89_USB` is new in 6.18) |
| `IWLMLD` | Intel Wi-Fi 7 / BE200 |

Only prompted symbols are listed; `RTW88_88XXA`, `RTW88_8812A`, `RTW88_8814A`,
`RTW88_8821A` and `RTW89_USB` are promptless and arrive via `select`. The
verifier checks those too, so a broken `select` is caught.

### Hardening

Debian 13 already sets `INIT_ON_ALLOC`, `SHUFFLE_PAGE_ALLOCATOR`,
`INIT_STACK_ALL_ZERO`, `BUG_ON_DATA_CORRUPTION`, `DEBUG_WX`,
`SECURITY_DMESG_RESTRICT` and `BPF_UNPRIV_DEFAULT_OFF`. The genuine deltas are:

- `INIT_ON_FREE_DEFAULT_ON`, `RANDOM_KMALLOC_CACHES`, `ZERO_CALL_USED_REGS`
- **`lockdown` removed from `CONFIG_LSM`** — it restricts `/dev/mem`, raw MSR
  access and unsigned module loading, which is exactly what pentest tooling
  needs. The LSM is still compiled in, so `lsm=` on the cmdline can re-enable it.

`HIBERNATION`, `KEXEC` and `KEXEC_FILE` are **left at Debian's `=y`**. An earlier
revision of the fragment disabled all three (Tails does); on amd64 this build
keeps suspend-to-disk and kdump working. `CONFIG_DEVKMEM` was also dropped from
the fragment — the symbol was removed upstream in 5.13, so that line was a
silent no-op.

`DEBUG_INFO_BTF` stays on so `bpftrace`/`bcc`/eBPF CO-RE work out of the box.
That forces full DWARF and a slow build; the symbols land in the `-dbg` package,
which is not shipped.

**`module.sig_enforce=1` must never go on the kernel command line.**
`MODULE_SIG_ALL=y` signs in-tree modules, but `sig_enforce` would reject every
DKMS module — the out-of-tree Realtek drivers, VirtualBox, nvidia. The old
`mk-iso.sh` set it; the current one does not, and `MODULE_SIG_FORCE` is off for
the same reason.

### Why `LOCALVERSION=` is passed explicitly

`scripts/setlocalversion` appends a `+` when `LOCALVERSION` is *unset* and the
tree is not at a signed tag — which is how the old build ended up named
`6.18.40-cybermyth+`. Setting the variable to the empty string suppresses it.

Note also that `make kernelrelease` reads `include/config/auto.conf`, **not**
`.config`. `olddefconfig` rewrites `.config` and leaves `auto.conf` stale, so
`build-kernel.sh` runs `syncconfig` before checking the release string.

## The live session

The live user is created **at boot by `live-config`**, not baked into the
squashfs. `/etc/live/config.conf` overrides live-config's defaults (which are
hostname `debian`, user `user`, fullname "Debian Live user"):

| | |
|---|---|
| user | `cybermyth` |
| password | `cybermyth` |
| hostname | `cybermyth` |

The password needs a custom component. live-config **hardcodes** the crypt of
`live` inside its `0030-user-setup` and offers no configuration hook, so
`mk-rootfs.sh` installs `/usr/lib/live/config/0035-cybermyth-password` — numbered
to run after the account exists (0030) and before any display manager (0080+).

Both can still be overridden from the GRUB command line:
`username=analyst hostname=box`.

`user-setup` is installed **explicitly**: it is only a `Recommends` of
live-config, and `--no-install-recommends` would drop it — after which
`0030-user-setup` exits early and no live user is ever created.

## Branding

Ported from the SP12 image build, minus its hardware-specific parts.

- `os-release`, `issue`, `issue.net`, `lsb-release`, `motd`, hostname — all
  behind `dpkg-divert` so a `base-files` upgrade cannot restore Debian branding.
- **Login screen** — GDM's backdrop is not a wallpaper and not a dconf key; it
  is `#lockDialogGroup { background-color: #222226; }` compiled into
  `gnome-shell-theme.gresource`. The gresource is unpacked, that one rule is
  rewritten to `#0a0d10`, and it is recompiled and diverted. The script
  *verifies* the substitution landed rather than assuming.
- **Wallpapers** — the repo's `gnome-backgrounds` (`48.2.1-1cybermyth2`) is the
  same package name at a higher version than Debian's, so GNOME's 24 wallpapers
  are never installed. `desktop-base` is the remaining source and **cannot be
  purged** (`gnome-control-center` depends on it), so its 10 picker XMLs are
  `dpkg-divert`ed out of the glob and its SVG wallpapers deleted, with
  `update-alternatives` repointed at the CyberMyth background so the
  `desktop-background` chain does not dangle.
- **Logos** — a filename sweep over `/usr/share` rewrites every
  `*debian*.{png,svg,jpg}` in place, recording each in a manifest. The audit
  compares against that manifest rather than counting filenames, because the
  files keep their package-owned "debian" *names* after their *contents* are
  replaced.

`mk-rootfs.sh` **fails** rather than shipping a half-branded image.

## Calamares

`calamares-settings-debian` supplies the module sequence and partitioning logic;
`calamares/` in this tree layers CyberMyth branding over it.

`settings.conf` differs from Debian's by exactly one line (`branding: cybermyth`)
— deliberately, so a Calamares upgrade that reorders modules is a one-line
rebase rather than a merge.

Two Debian-specific behaviours are overridden:

- `branding.desc` sets `bootloaderEntryName: CyberMyth`. Debian's says `Debian`,
  which would put "Debian" in the GRUB menu of every installed machine.
- `packages.conf` additionally removes `calamares` itself and
  `live-boot-initramfs-tools` from the target. Debian's list removes the
  settings package but leaves the Calamares binary, putting a broken installer
  in the app grid of every installed system.

### Every name in packages.conf must be an installed package

The `packages` module runs, literally, in the target root:

```
apt-get --purge -q -y remove <every name in packages.conf>
```

apt resolves an **installed** package from `/var/lib/dpkg/status` and needs no
index. But a name that is neither installed nor in any index is fatal —
`E: Unable to locate package X`, exit 100 — and Calamares surfaces it as:

> Installation failed after bootloader installation finished.
> The package manager could not make changes to the installed system.

`calamares-settings-debian`'s stock list names `live-boot-doc`,
`live-config-doc`, `live-task-localisation` and `live-task-recommended`.
Debian's live ISO gets away with that because **its medium carries a full
`pool/` + `dists/`**, so apt can locate those names even though they are not
installed. This ISO has no pool, and `mk-rootfs.sh` empties
`/var/lib/apt/lists`, so on a machine with no network during install apt knows
only what is installed. All four are removed from our list.

This shipped in the first ISO and is only discoverable by *actually installing* —
the live session boots and runs perfectly either way. `mk-rootfs.sh` now asserts
at build time that every name in `packages.conf` is installed in the rootfs.

### The "Install" menu entry

There is **no** `calamares.autostart` kernel parameter — Debian's autostart entry
(`calamares-desktop-icon.desktop`) only drops an icon on the desktop and never
launches the installer. The GRUB "Install CyberMyth OS" entry therefore passes
`cybermyth.install`, which `/usr/local/bin/cybermyth-install-autostart` (shipped
by `mk-rootfs.sh`) greps out of `/proc/cmdline`. On the plain Live entry it exits
immediately.

## ISO layout

These paths are not arbitrary:

| Path | Why |
|---|---|
| `/live/filesystem.squashfs` | `unpackfs.conf` reads exactly `/run/live/medium/live/filesystem.squashfs` |
| `/live/vmlinuz`, `/live/initrd.img` | referenced by `grub.cfg` |
| `/boot/grub/grub.cfg` | the visible menu — editable without rebuilding the EFI binary |
| appended partition 2 | FAT ESP holding `EFI/BOOT/BOOTX64.EFI` — **not** a file in the ISO tree |
| `/.disk/cybermyth.id` | the marker GRUB `search`es for to locate its own root |

`bootx64.efi` is a `grub-mkstandalone` image whose *embedded* config does nothing
but find the ISO and `configfile` the real `grub.cfg`. Modules are embedded
rather than loaded from the ISO because `$prefix` is not yet known at that point.

### Making a dd'd USB stick bootable

The ESP is attached with:

```
-e '--interval:appended_partition_2:all::' -no-emul-boot
-append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$EFIIMG"
-appended_part_as_gpt
```

`-append_partition` adds the FAT image to the end of the ISO as a real GPT
partition typed *EFI System*, which is what firmware looks for on a USB stick;
`-e --interval:appended_partition_2:all::` points the El Torito entry at those
same bytes, so optical/virtual-CD boot works and the ESP is stored once.
`-append_partition` takes a **filesystem** path, not an ISO-relative one.

> **Do not use `-isohybrid-gpt-basdat` here.** It belongs to xorriso's
> isohybrid/isolinux machinery and is a no-op without `-isohybrid-mbr`, which
> this UEFI-only image does not use. It fails *silently*: xorriso reports
> success and produces an ISO with **no partition table at all** — bootable as a
> virtual CD, dead from USB. An earlier revision of `mk-iso.sh` shipped this.

`mk-iso.sh` verifies the protective MBR, the GPT, the EFI System type GUID and
the UEFI El Torito entry by asking **xorriso** (`-report_system_area`,
`-report_el_torito`), not `fdisk` — xorriso is already a hard requirement, while
`fdisk` lives in `/sbin` and may not be on `PATH`, in which case a piped check
with stderr discarded looks identical to a missing partition.

## Known limitations

- **UEFI x64 only.** No legacy BIOS boot path. Adding one means an `isolinux`
  or `grub-pc` El Torito entry plus `-isohybrid-mbr`.
- **Secure Boot must be disabled.** The kernel is signed by a build-generated
  key that is in no firmware db. shim + MOK enrolment is a later build.
- `tor-browser` is 15.0.21 on amd64 but 16.0~a9-1 on arm64 — upstream ships no
  stable Linux arm64 build, so the two arches legitimately differ.
