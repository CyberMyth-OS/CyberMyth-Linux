#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Toshith Yadav
#
# Build the CyberMyth OS amd64 live root filesystem.
#
#   sudo ./mk-rootfs.sh [--fresh]
#
# Produces ./rootfs, which mk-iso.sh then squashes into a bootable ISO.
#
# DESIGN NOTES -- read before editing
#
# * NO BACKPORTS. Not in sources.list, not via -t, nowhere. The SP12 build pulls
#   Mesa from trixie-backports for the Adreno X1-45; amd64 needs nothing of the
#   sort, and trixie's Mesa 25.0.7 is correct here. cybermyth-desktop 1.0.3
#   dropped the mesa pins for exactly this reason (they moved to cybermyth-sp12).
#
# * MINIMAL PACKAGE LIST. cybermyth-core and cybermyth-desktop ARE the product
#   definition. Anything they already pull is deliberately NOT repeated below --
#   this script installs only live/installer infrastructure, firmware, boot
#   plumbing, and nmap. If you want another tool in the OS, add it to the
#   metapackage in the repo, not here.
#
# * FIRMWARE comes from Debian, pinned away from the CyberMyth repo's own
#   firmware-linux. That package is an arm64-oriented metapackage that
#   deliberately EXCLUDES desktop GPU microcode -- exactly wrong for amd64.
#   linux-firmware-extra is likewise excluded: 122 of its 164 files collide with
#   Debian's amd64 firmware packages and it declares no Replaces.
#
# * The live user is created at boot by live-config, not baked in here.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOTFS=${ROOTFS:-$HERE/rootfs}
BRAND=$HERE/branding
PKGDIR=$HERE/pkg
KEYRING=$HERE/keyring/cybermyth-archive-keyring.gpg
CALDIR=$HERE/calamares

SUITE=trixie
MIRROR=${MIRROR:-http://deb.debian.org/debian}
KREL=6.18.49-cybermyth-amd64

OS_NAME="CyberMyth OS"
OS_ID=cybermyth
OS_VERSION="1.0"
HOSTNAME=cybermyth
LIVE_USER=cybermyth
LIVE_PASS=cybermyth

CM_REPO=${CM_REPO:-1}
CM_REPO_HOST=repo.cybermyth.dev
CM_REPO_URL=https://$CM_REPO_HOST

die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo $0)"

# --- Preflight ---------------------------------------------------------------
# Fail here, with a sentence that says what to do, rather than an hour in.
step "Preflight"

for t in debootstrap chroot magick gresource glib-compile-resources unzip; do
    command -v "$t" >/dev/null 2>&1 \
        || die "missing host tool: $t
    apt install -y debootstrap imagemagick libglib2.0-bin libglib2.0-dev-bin unzip"
done

KIMG=$(ls -1 "$PKGDIR"/linux-image-"$KREL"_*_amd64.deb 2>/dev/null | grep -v -- '-dbg' | head -1) || true
KHDR=$(ls -1 "$PKGDIR"/linux-headers-"$KREL"_*_amd64.deb 2>/dev/null | head -1) || true
[ -n "${KIMG:-}" ] || die "no kernel image package for $KREL in $PKGDIR
    Build it first:  kernel/build-kernel.sh"
[ -n "${KHDR:-}" ] || die "no kernel headers package for $KREL in $PKGDIR"
note "kernel image  : $(basename "$KIMG")"
note "kernel headers: $(basename "$KHDR")"

for f in "$BRAND/cm-logo-512.png" "$BRAND/cm-logo-256.png" "$BRAND/cm-logo-128.png" \
         "$BRAND/cm-logo-64.png" "$BRAND/cm-logo-text-version-64.png" \
         "$BRAND/cybermyth-bg.png" "$BRAND/cybermyth-theme.zip" \
         "$BRAND/wolf-transparent.png" "$BRAND/motd"; do
    [ -f "$f" ] || die "missing branding asset: $f"
done

[ -f "$KEYRING" ] || die "missing CyberMyth archive keyring: $KEYRING"

# The CyberMyth repo is not optional: cybermyth-core and cybermyth-desktop have
# no other source, and they ARE the product. Check reachability now, because an
# unreachable repo makes every apt call in the chroot fail opaquely.
if [ "$CM_REPO" = "1" ]; then
    printf '    checking %s ... ' "$CM_REPO_URL"
    if curl -fsS --max-time 30 -o /dev/null "$CM_REPO_URL/dists/stable/InRelease"; then
        printf 'serving\n'
    else
        printf 'UNREACHABLE\n'
        die "cannot fetch $CM_REPO_URL/dists/stable/InRelease
Every apt operation in this build would fail against that source."
    fi
fi

# tor-browser is a hard dependency of cybermyth-desktop and was arm64-only in
# the repo. Warn early if the amd64 build has not been pushed yet, naming the
# fix, instead of failing deep inside apt's resolver.
if [ "$CM_REPO" = "1" ]; then
    # See the grep -q / SIGPIPE note at the initramfs check below.
    if curl -fsS --max-time 30 "$CM_REPO_URL/dists/stable/main/binary-amd64/Packages" \
       | grep '^Package: tor-browser$' >/dev/null; then
        note "tor-browser: present in the amd64 index"
    else
        printf '\n\033[1;33m    WARNING: tor-browser is NOT in the repo amd64 index.\033[0m\n'
        printf '    cybermyth-desktop depends on it and WILL fail to install.\n'
        printf '    Build and push it first:  pkg/build-tor-browser.sh\n\n'
    fi
fi

# --- Resumable staging -------------------------------------------------------
# Each expensive stage records completion beside the rootfs, so a late failure
# in branding or initramfs does not repeat debootstrap and apt.
STATE=$ROOTFS.state
if [ "${1:-}" = "--fresh" ]; then
    step "Removing $ROOTFS"
    rm -rf "$ROOTFS" "$STATE"
fi
[ -d "$ROOTFS" ] || rm -f "$STATE"

done_stage() { [ -f "$STATE" ] && grep -qx "$1" "$STATE"; }
mark_stage() { printf '%s\n' "$1" >> "$STATE"; sync; }
skip()       { printf '    [skip] %s already done\n' "$1"; }

# A rootfs directory with no state file is not a resumable build -- it is
# leftovers from some other run (the abandoned 6.18.40 attempt left one).
# debootstrapping over it would silently mix two systems, so refuse.
if [ -d "$ROOTFS" ] && [ ! -f "$STATE" ]; then
    die "$ROOTFS exists but $STATE does not.
That directory is not a resumable build of this script -- most likely leftovers
from an earlier attempt. Bootstrapping over it would mix two systems.
Start clean:
    sudo $0 --fresh"
fi
if [ -d "$ROOTFS" ] && [ -f "$STATE" ]; then
    note "resuming; completed stages: $(tr '\n' ' ' < "$STATE")"
fi

# Deepest first: /dev/pts is under /dev, so unmounting /dev first would leave it
# orphaned. Used both by the EXIT trap and explicitly once the chroot work is
# done -- see "Unmounting pseudo-filesystems" below.
unmount_pseudo() {
    local d
    for d in dev/pts dev proc sys run; do
        if mountpoint -q "$ROOTFS/$d" 2>/dev/null; then umount -l "$ROOTFS/$d"; fi
    done
}
cleanup() {
    set +e
    unmount_pseudo
    set -e
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$ROOTFS"

# --- Base system -------------------------------------------------------------
# debootstrap only bootstraps a minimal base. It is NOT a package manager: given
# a large --include it configures hundreds of packages in one pass with naive
# ordering. apt resolves ordering properly, so everything else goes in below.
if done_stage DEBOOTSTRAP; then skip DEBOOTSTRAP; else
step "debootstrap $SUITE amd64"
debootstrap --arch=amd64 \
    --components=main,contrib,non-free-firmware,non-free \
    --include=systemd,systemd-sysv,udev,kmod,dbus,ca-certificates,apt-utils,less,nano \
    "$SUITE" "$ROOTFS" "$MIRROR"
mark_stage DEBOOTSTRAP
fi

# --- APT sources -------------------------------------------------------------
# Outside the stage guard on purpose: a resumed build skips DEBOOTSTRAP and the
# sources must still be present and correct.
step "Configuring APT sources"
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
# CyberMyth OS -- Debian $SUITE. NO backports, deliberately.
deb $MIRROR $SUITE main contrib non-free-firmware non-free
deb $MIRROR ${SUITE}-updates main contrib non-free-firmware non-free
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware non-free
EOF

mkdir -p "$ROOTFS/etc/apt/sources.list.d" "$ROOTFS/etc/apt/preferences.d"

if [ "$CM_REPO" = "1" ]; then
    install -D -m 0644 "$KEYRING" \
        "$ROOTFS/usr/share/keyrings/cybermyth-archive-keyring.gpg"
    cat > "$ROOTFS/etc/apt/sources.list.d/cybermyth.sources" <<EOF
Types: deb
URIs: $CM_REPO_URL/
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/cybermyth-archive-keyring.gpg
EOF
    # 700 beats Debian's 500 so CyberMyth wins on equal or newer versions.
    # Deliberately NOT 1001, which would force downgrades of Debian packages and
    # let one stale package here hold back security updates.
    cat > "$ROOTFS/etc/apt/preferences.d/cybermyth" <<EOF
Package: *
Pin: origin $CM_REPO_HOST
Pin-Priority: 700
EOF
    # The two firmware packages that must NEVER come from the CyberMyth repo on
    # amd64. Both are arm64-shaped:
    #   firmware-linux        (20260810-cybermyth1) is a metapackage that
    #                         deliberately OMITS desktop GPU microcode -- it
    #                         exists to keep 275 MB of amdgpu/i915/nvidia blobs
    #                         off a Surface tablet. On amd64 that is exactly the
    #                         firmware we need, so Debian's must win.
    #   linux-firmware-extra  122 of its 164 files are also in Debian's
    #                         firmware-misc-nonfree, firmware-realtek,
    #                         firmware-brcm80211, firmware-mediatek,
    #                         firmware-siano and firmware-libertas, and it
    #                         declares no Replaces -- dpkg would refuse to
    #                         unpack it. Its only unique wireless value on amd64
    #                         is four newer rtw89 blobs; ath9k_htc and carl9170
    #                         are already in Debian main.
    # -1 means "never", which is what we want: not a version preference, an
    # exclusion. Both are arch:all so they DO appear in the amd64 index.
    # No firmware preferences file is needed here any more.
    #
    # There used to be one, because the CyberMyth repo's arm64 firmware-linux
    # and linux-firmware-extra were built Architecture: all and so appeared in
    # the amd64 index, colliding with Debian's firmware-linux. They are now
    # Architecture: arm64 and Debian's is Architecture: amd64, so neither is
    # visible to the other's clients and reprepro keeps them in separate
    # indices. Fixing the architectures removed the need for the pin rather
    # than working around it.
    #
    # The runtime assertion after the CyberMyth package stage still checks that
    # the installed firmware-linux is not a *cybermyth* build, so a regression
    # here fails the build loudly instead of silently shipping arm64 firmware.
    rm -f "$ROOTFS/etc/apt/preferences.d/cybermyth-no-arm64-firmware"
    note "CyberMyth repo pinned 700 (no firmware pin needed: packages are arch-split)"
else
    rm -f "$ROOTFS/etc/apt/sources.list.d/cybermyth.sources" \
          "$ROOTFS/etc/apt/preferences.d/cybermyth" \
          "$ROOTFS/etc/apt/preferences.d/cybermyth-no-arm64-firmware"
    note "building WITHOUT the CyberMyth repo (CM_REPO=0) -- cybermyth-* will fail"
fi

# Belt and braces: if a stray backports source ever appears, refuse it outright
# rather than let a -t or a Recommends quietly pull from it.
cat > "$ROOTFS/etc/apt/preferences.d/no-backports" <<EOF
# CyberMyth OS amd64 takes NOTHING from backports. trixie-backports is
# NotAutomatic (priority 100) so this is belt and braces, but it makes the
# policy explicit and survives someone adding the source by hand.
Package: *
Pin: release n=${SUITE}-backports
Pin-Priority: -1
EOF

# --- Bind mounts (idempotent; required on every run including resumes) --------
mountpoint -q "$ROOTFS/dev"     || mount --bind /dev     "$ROOTFS/dev"
mountpoint -q "$ROOTFS/dev/pts" || mount --bind /dev/pts "$ROOTFS/dev/pts"
mountpoint -q "$ROOTFS/proc"    || mount -t proc  proc  "$ROOTFS/proc"
mountpoint -q "$ROOTFS/sys"     || mount -t sysfs sysfs "$ROOTFS/sys"

# Keep services from starting inside the chroot.
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

# --- Packages ----------------------------------------------------------------
if done_stage APT; then skip APT; else
step "Installing Debian packages (staged)"
chroot "$ROOTFS" /bin/bash -eu <<'APT'
export DEBIAN_FRONTEND=noninteractive

# A previous run that died mid-unpack leaves half-configured packages, and every
# later apt-get then refuses to do anything until dpkg is put right. This stage
# is not marked complete unless it finishes, so a re-run lands here first.
dpkg --configure -a || true

apt-get update -qq

# --- 1. live system + installer infrastructure ------------------------------
# user-setup is only a Recommends of live-config, and --no-install-recommends
# would silently drop it -- without it live-config's 0030-user-setup component
# exits early and NO live user is ever created. Name it explicitly.
apt-get install -y --no-install-recommends \
    live-boot live-boot-initramfs-tools live-config live-config-systemd \
    live-tools user-setup sudo initramfs-tools locales keyboard-configuration \
    console-setup

# --- 2. installer ------------------------------------------------------------
# Recommends left ON: calamares recommends btrfs-progs and squashfs-tools, and
# unpackfs cannot copy the live filesystem without the latter.
apt-get install -y calamares calamares-settings-debian

# --- 3. boot plumbing --------------------------------------------------------
# UEFI x64 only for this first image; shim/MOK Secure Boot comes later.
apt-get install -y --no-install-recommends \
    grub-efi-amd64 grub-efi-amd64-bin grub-common efibootmgr os-prober \
    dosfstools parted gdisk cryptsetup btrfs-progs xfsprogs e2fsprogs \
    squashfs-tools

# --- 4. hardware and networking not covered by cybermyth-core ---------------
apt-get install -y --no-install-recommends \
    network-manager bluez rfkill pciutils usbutils \
    iw wireless-regdb wpasupplicant iputils-ping \
    zstd unzip

# --- 5. firmware -------------------------------------------------------------
# firmware-ipw2x00 is the ONE package in this list with a debconf licence gate
# (verified by inspecting the control archive of all 31): its preinst asks
# firmware-ipw2x00/license/accepted, whose Default is false. Under
# DEBIAN_FRONTEND=noninteractive the question cannot be asked, so the preinst
# exits non-zero and takes the whole apt run down with it:
#     Errors were encountered while processing:
#      .../firmware-ipw2x00_20250410-2_all.deb
# Preseeding the answer is the supported way through; it is also what Debian's
# own live images do to ship this firmware.
#
# THIS ACCEPTS THE INTEL PRO/WIRELESS 2100 AND 2200/2915 LICENCE ON THE USER'S
# BEHALF. The firmware is for Centrino-era (2003-2005) Intel wireless. To ship
# without agreeing, delete this preseed AND remove firmware-ipw2x00 from the
# apt-get line below -- nothing else depends on it.
echo 'firmware-ipw2x00 firmware-ipw2x00/license/accepted boolean true' \
    | debconf-set-selections
# Debian's set, not the CyberMyth repo's (see the pin written above).
# firmware-linux only pulls firmware-misc-nonfree and firmware-amd-graphics, so
# every wireless/audio/GPU vendor has to be named. firmware-ath9k-htc and
# firmware-carl9170 are in MAIN, not non-free-firmware -- they are the AR9271 /
# AR9170 injection dongles and matter for an offsec distro.
apt-get install -y --no-install-recommends \
    firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
    firmware-amd-graphics firmware-nvidia-graphics \
    firmware-intel-graphics firmware-intel-misc firmware-intel-sound \
    firmware-sof-signed firmware-cirrus \
    firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 \
    firmware-mediatek firmware-libertas firmware-ti-connectivity \
    firmware-zd1211 firmware-ipw2x00 firmware-ath9k-htc firmware-carl9170 \
    firmware-bnx2 firmware-bnx2x firmware-qlogic firmware-myricom \
    firmware-netxen firmware-siano firmware-samsung bluez-firmware \
    intel-microcode amd64-microcode

# --- 6. the one offsec tool not already pulled by cybermyth-core -------------
apt-get install -y --no-install-recommends nmap

apt-get clean
rm -rf /var/lib/apt/lists/*
APT
mark_stage APT
fi

# --- CyberMyth packages ------------------------------------------------------
# cybermyth-core and cybermyth-desktop ARE the product. No CM_REPO guard and no
# graceful degradation: building with CM_REPO=0 removes the only source these
# can come from, and this stage then fails, correctly and loudly.
#
# Recommends deliberately left ON -- these are the metapackages that define the
# product, and --no-install-recommends would quietly drop parts of it.
if done_stage CMPKGS; then skip CMPKGS; else
step "Installing CyberMyth packages"
chroot "$ROOTFS" /bin/bash -eu <<'CMPKGS'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y cybermyth-core cybermyth-desktop

echo "--- cybermyth packages installed ---"
dpkg-query -W -f='${Package} ${Version}\n' \
    cybermyth-core cybermyth-desktop anonymity-cli tor-browser \
    gnome-backgrounds gnome-rounded-corners 2>/dev/null || true

echo "--- firmware-linux must be Debian's, not the repo's ---"
dpkg-query -W -f='${Package} ${Version}\n' firmware-linux
apt-get clean
rm -rf /var/lib/apt/lists/*
CMPKGS
# Fail the build rather than ship the wrong firmware metapackage.
fwver=$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' firmware-linux 2>/dev/null || echo "")
case "$fwver" in
    *cybermyth*) die "firmware-linux is the CyberMyth arm64 metapackage ($fwver).
That package is Architecture: arm64 and must not be visible here at all -- if it
is, it has been republished as Architecture: all. Rebuild it arm64:
    pkg/rearch-firmware.sh" ;;
    "")          die "firmware-linux is not installed" ;;
    *)           note "firmware-linux $fwver (Debian) -- correct" ;;
esac

# The check that actually matters. Debian 13's firmware is 20250410, built for
# Debian's 6.12 kernel; 6.18 raised iwlwifi's minimum firmware API to 100
# (IWL_BZ_UCODE_API_MIN, drivers/net/wireless/intel/iwlwifi/cfg/bz.c) and trixie
# tops out at 97. The first ISO booted with Bluetooth but NO WI-FI on Intel
# Wi-Fi 7 for exactly this reason, and nothing in the build noticed, because
# every package "installed successfully" -- the firmware was simply too old.
#
# So assert the file, not the package version.
IWLDIR=$ROOTFS/usr/lib/firmware
iwlhi=$(ls "$IWLDIR"/iwlwifi-gl-c0-fm-c0-*.ucode 2>/dev/null \
        | sed -nE 's/.*-([0-9]+)\.ucode$/\1/p' | sort -n | tail -1)
if [ -z "${iwlhi:-}" ]; then
    die "no iwlwifi-gl-c0-fm-c0-*.ucode in the rootfs at all -- firmware-iwlwifi is missing"
elif [ "$iwlhi" -lt 100 ]; then
    die "iwlwifi Wi-Fi 7 firmware tops out at API $iwlhi, but linux-6.18.49 requires 100.
Intel Wi-Fi 7 hardware will have NO WI-FI (Bluetooth will still work, which
makes this easy to miss). The CyberMyth repo must carry the linux-firmware
20260810 set:  pkg/fetch-firmware.sh && pkg/push-firmware.sh"
else
    note "iwlwifi Wi-Fi 7 firmware: API $iwlhi (>= 100 required by 6.18) -- correct"
fi
mark_stage CMPKGS
fi

# --- Kernel ------------------------------------------------------------------
if done_stage KERNEL; then skip KERNEL; else
step "Installing the CyberMyth kernel"
mkdir -p "$ROOTFS/tmp/kpkg"
cp "$KIMG" "$KHDR" "$ROOTFS/tmp/kpkg/"
# apt-get install on local files, not dpkg -i: apt resolves the dependencies
# (initramfs-tools et al) instead of leaving a half-configured package behind.
chroot "$ROOTFS" /bin/bash -eu <<'KERN'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y --no-install-recommends /tmp/kpkg/*.deb
KERN
rm -rf "$ROOTFS/tmp/kpkg"
[ -e "$ROOTFS/boot/vmlinuz-$KREL" ] || die "kernel image not installed as /boot/vmlinuz-$KREL"
[ -d "$ROOTFS/lib/modules/$KREL" ] || die "modules not installed for $KREL"
note "installed $KREL"
mark_stage KERNEL
fi

# --- live-config -------------------------------------------------------------
# Not stage-guarded: cheap and idempotent, and this is the file most likely to
# be tweaked between runs.
step "Configuring live-config"
mkdir -p "$ROOTFS/etc/live"
cat > "$ROOTFS/etc/live/config.conf" <<EOF
# CyberMyth OS live session defaults.
# live-config's own defaults are hostname "debian", user "user", fullname
# "Debian Live user" -- all three are user-visible, so all three are overridden.
# Any of these can still be changed from the GRUB command line, e.g.
#   username=analyst hostname=box
LIVE_HOSTNAME="$HOSTNAME"
LIVE_USERNAME="$LIVE_USER"
LIVE_USER_FULLNAME="CyberMyth"
# sudo is deliberately absent: live-config's 0040-sudo component adds the user
# to the sudo group AND writes /etc/sudoers.d/live, so listing it here too would
# be redundant.
LIVE_USER_DEFAULT_GROUPS="audio cdrom dip floppy video plugdev netdev powerdev scanner bluetooth debian-tor"
EOF

# live-config hardcodes the live password to the crypt of "live" inside its
# 0030-user-setup component -- it is NOT read from config.conf, so there is no
# supported way to set it declaratively. A component of our own, ordered after
# user-setup (0030) and before the display managers (0080), sets it instead.
cat > "$ROOTFS/usr/lib/live/config/0035-cybermyth-password" <<EOF
#!/bin/sh
# CyberMyth OS: set the live user's password.
#
# live-config's 0030-user-setup hardcodes the crypt of "live" and offers no
# configuration hook for it, so this component runs straight afterwards and
# resets the password to the CyberMyth default. Numbered 0035 so it lands
# between user-setup (0030) and the display-manager components (0080+), i.e.
# after the account exists and before anything tries to log in as it.

. /usr/lib/live/config.sh

Init ()
{
	if ! grep -q "^\${LIVE_USERNAME}:" /etc/passwd
	then
		exit 0
	fi
	echo -n " cybermyth-password"
}

Config ()
{
	echo "\${LIVE_USERNAME}:$LIVE_PASS" | chpasswd
	touch /var/lib/live/config/cybermyth-password
}

Init
Config
EOF
chmod 0755 "$ROOTFS/usr/lib/live/config/0035-cybermyth-password"
note "live user: $LIVE_USER / $LIVE_PASS   hostname: $HOSTNAME"

# --- Branding ----------------------------------------------------------------
step "Applying CyberMyth branding"

install -D -m 0644 "$BRAND/cm-logo-256.png" "$ROOTFS/usr/share/pixmaps/cybermyth.png"
install -D -m 0644 "$BRAND/cm-logo-512.png" "$ROOTFS/usr/share/pixmaps/cybermyth-512.png"
# NOTE: /usr/share/backgrounds/cybermyth.png is NOT installed here. It is owned
# by the repo's gnome-backgrounds (48.2.1-1cybermyth2), which also ships the
# mystic-* wallpapers and both picker XMLs, and replaces Debian's 24 GNOME
# wallpapers outright by being the same package name at a higher version.
# Writing over a package-owned path here would only desync dpkg.

# /etc/os-release is a symlink to /usr/lib/os-release owned by base-files.
# cybermyth-core already ships /usr/lib/os-release; divert so no base-files
# upgrade can restore Debian branding.
chroot "$ROOTFS" dpkg-divert --local --rename --add /usr/lib/os-release >/dev/null 2>&1 || true
cat > "$ROOTFS/usr/lib/os-release" <<EOF
PRETTY_NAME="$OS_NAME $OS_VERSION"
NAME="$OS_NAME"
VERSION_ID="$OS_VERSION"
VERSION="$OS_VERSION"
VERSION_CODENAME=$SUITE
ID=$OS_ID
ID_LIKE=debian
ANSI_COLOR="1;36"
LOGO=cybermyth
HOME_URL="https://cybermyth.dev"
EOF
rm -f "$ROOTFS/etc/os-release"
ln -sf ../usr/lib/os-release "$ROOTFS/etc/os-release"

chroot "$ROOTFS" dpkg-divert --local --rename --add /etc/issue     >/dev/null 2>&1 || true
chroot "$ROOTFS" dpkg-divert --local --rename --add /etc/issue.net >/dev/null 2>&1 || true
printf '%s %s \\n \\l\n\n' "$OS_NAME" "$OS_VERSION" > "$ROOTFS/etc/issue"
printf '%s %s\n' "$OS_NAME" "$OS_VERSION" > "$ROOTFS/etc/issue.net"
cat > "$ROOTFS/etc/lsb-release" <<EOF
DISTRIB_ID=CyberMyth
DISTRIB_RELEASE=$OS_VERSION
DISTRIB_CODENAME=cybermyth
DISTRIB_DESCRIPTION="$OS_NAME $OS_VERSION"
EOF
printf '%s\n%s %s\n\n' "$(cat "$BRAND/motd")" "$OS_NAME" "$OS_VERSION" > "$ROOTFS/etc/motd"
echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" > "$ROOTFS/etc/hosts"

# --- Plymouth boot splash ----------------------------------------------------
step "Installing the Plymouth theme"
THEME=$ROOTFS/usr/share/plymouth/themes/cybermyth
mkdir -p "$THEME"
install -m 0644 "$BRAND/cm-logo-512.png" "$THEME/logo.png"
cat > "$THEME/cybermyth.plymouth" <<'EOF'
[Plymouth Theme]
Name=CyberMyth
Description=CyberMyth OS boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/cybermyth
ScriptFile=/usr/share/plymouth/themes/cybermyth/cybermyth.script
EOF
# Deliberately minimal. A runtime error in a Plymouth script renders NOTHING --
# a blank screen -- so this avoids anything whose existence is not certain
# (no Math.*, no Plymouth.GetTime). A counter driven by the refresh callback is
# the documented way to animate.
cat > "$THEME/cybermyth.script" <<'EOF'
Window.SetBackgroundTopColor(0.039, 0.051, 0.063);
Window.SetBackgroundBottomColor(0.020, 0.027, 0.035);

logo.image  = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth()  / 2 - logo.image.GetWidth()  / 2);
logo.sprite.SetY(Window.GetHeight() / 2 - logo.image.GetHeight() / 2);
logo.sprite.SetZ(0);

progress = 0;
fun refresh_callback() {
    progress++;
    # simple triangular fade, no math library needed
    phase = progress % 100;
    if (phase > 50) phase = 100 - phase;
    logo.sprite.SetOpacity(0.6 + phase / 125);
}
Plymouth.SetRefreshFunction(refresh_callback);

fun quit_callback() {
    logo.sprite.SetOpacity(1);
}
Plymouth.SetQuitFunction(quit_callback);
EOF

# --- GNOME defaults ----------------------------------------------------------
mkdir -p "$ROOTFS/usr/share/glib-2.0/schemas"
cat > "$ROOTFS/usr/share/glib-2.0/schemas/99_cybermyth.gschema.override" <<'EOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/cybermyth.png'
picture-uri-dark='file:///usr/share/backgrounds/cybermyth.png'
primary-color='#0a0d10'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/cybermyth.png'
primary-color='#0a0d10'

[org.gnome.desktop.interface]
color-scheme='prefer-dark'

[org.gnome.shell]
enabled-extensions=['cybermyth-theme@cybermyth.dev']
favorite-apps=['calamares-install-debian.desktop', 'firefox-esr.desktop', 'tor-browser.desktop', 'com.gexperts.Tilix.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Settings.desktop']
EOF

# --- Login screen colour -----------------------------------------------------
# GDM's backdrop is not a wallpaper and not a dconf key: it is the CSS rule
#     #lockDialogGroup { background-color: #222226; }
# compiled into /usr/share/gnome-shell/gnome-shell-theme.gresource. That #222226
# is Debian's grey on the login and lock screens, and nothing in dconf or
# /etc/gdm3 can override it.
CM_LOGIN_BG='#0a0d10'
step "Recolouring the login screen"
GST_REL=/usr/share/gnome-shell/gnome-shell-theme.gresource
GST=$ROOTFS$GST_REL
if [ ! -f "$GST" ]; then
    note "gnome-shell theme gresource absent -- skipped"
else
    GRT=$(mktemp -d)
    mkdir -p "$GRT/theme"
    gresource list "$GST" > "$GRT/list.txt"
    while IFS= read -r res; do
        [ -n "$res" ] || continue
        gresource extract "$GST" "$res" > "$GRT/theme/$(basename "$res")"
    done < "$GRT/list.txt"

    # The rule spans two lines: the selector, then the declaration -- so match
    # the selector and edit the line AFTER it, rather than every
    # background-color in a 175 KB stylesheet.
    patched=0
    for css in "$GRT"/theme/gnome-shell-dark.css \
               "$GRT"/theme/gnome-shell-light.css \
               "$GRT"/theme/gnome-shell-high-contrast.css; do
        [ -f "$css" ] || continue
        sed -i "/^#lockDialogGroup {\$/{n;s/background-color: *#[0-9a-fA-F]\{3,8\}/background-color: $CM_LOGIN_BG/}" "$css"
        # Verify rather than assume: a silently failed sed would ship Debian's
        # grey while reporting success.
        if grep -A1 '^#lockDialogGroup {$' "$css" | grep -F "$CM_LOGIN_BG" >/dev/null; then
            patched=$((patched+1))
        else
            rm -rf "$GRT"; die "failed to recolour #lockDialogGroup in $(basename "$css") -- upstream CSS layout changed"
        fi
    done
    [ "$patched" -gt 0 ] || { rm -rf "$GRT"; die "no gnome-shell stylesheets found in the gresource"; }

    # Uncompressed, to match how Debian ships it.
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<gresources>\n'
        printf '  <gresource prefix="/org/gnome/shell/theme">\n'
        while IFS= read -r res; do
            [ -n "$res" ] || continue
            printf '    <file>%s</file>\n' "$(basename "$res")"
        done < "$GRT/list.txt"
        printf '  </gresource>\n</gresources>\n'
    } > "$GRT/theme/cybermyth-theme.gresource.xml"

    glib-compile-resources --sourcedir="$GRT/theme" \
        --target="$GRT/new.gresource" "$GRT/theme/cybermyth-theme.gresource.xml" \
        || { rm -rf "$GRT"; die "glib-compile-resources failed for the shell theme"; }

    chroot "$ROOTFS" dpkg-divert --local --rename \
        --divert "$GST_REL.debian" --add "$GST_REL" >/dev/null 2>&1 || true
    install -m 0644 "$GRT/new.gresource" "$GST"
    note "login backdrop -> $CM_LOGIN_BG ($patched stylesheet(s))"
    rm -rf "$GRT"
fi

# --- Replace every Debian logo with the CyberMyth wolf ------------------------
step "Replacing Debian logos"
svg_wrap() {
    _src=$1; _dst=$2
    _w=$(magick identify -format '%w' "$_src")
    _h=$(magick identify -format '%h' "$_src")
    {
        printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%s" height="%s" viewBox="0 0 %s %s">\n' "$_w" "$_h" "$_w" "$_h"
        printf '<image width="%s" height="%s" xlink:href="data:image/png;base64,%s"/>\n' "$_w" "$_h" "$(base64 -w0 "$_src")"
        printf '</svg>\n'
    } > "$_dst"
}

DBL=$ROOTFS/usr/share/desktop-base/debian-logos
if [ -d "$DBL" ]; then
    for sz in 64 128 256; do
        for variant in "" "-text" "-text-version"; do
            src=$BRAND/cm-logo${variant}-${sz}.png
            dst=$DBL/logo${variant}-${sz}.png
            [ -f "$src" ] && install -m 0644 "$src" "$dst"
        done
    done
    for variant in "" "-text" "-text-version"; do
        [ -e "$DBL/logo${variant}.svg" ] && \
            svg_wrap "$BRAND/cm-logo${variant}-256.png" "$DBL/logo${variant}.svg"
    done
    note "replaced $(ls -1 "$DBL" | wc -l) logo files"
fi

for d in "$ROOTFS/usr/share/icons/desktop-base" "$ROOTFS/usr/share/icons/hicolor" \
         "$ROOTFS/usr/share/icons/vendor"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
        px=$(basename "$(dirname "$(dirname "$f")")"); px=${px%%x*}
        case "$px" in ''|*[!0-9]*) px=256 ;; esac
        magick "$BRAND/wolf-transparent.png" -resize x"$px" -background none \
            -gravity center -extent "${px}x${px}" "$f" 2>/dev/null || true
    done < <(find "$d" -name 'emblem-debian*.png' 2>/dev/null)
    while IFS= read -r f; do
        svg_wrap "$BRAND/cm-logo-256.png" "$f" 2>/dev/null || true
    done < <(find "$d" -name 'emblem-debian*.svg' 2>/dev/null)
done

# os-release LOGO=cybermyth resolves through the icon theme
install -D -m 0644 "$BRAND/cm-logo-256.png" "$ROOTFS/usr/share/icons/hicolor/256x256/apps/cybermyth.png"
install -D -m 0644 "$BRAND/cm-logo-128.png" "$ROOTFS/usr/share/icons/hicolor/128x128/apps/cybermyth.png"
install -D -m 0644 "$BRAND/cm-logo-64.png"  "$ROOTFS/usr/share/icons/hicolor/64x64/apps/cybermyth.png"
install -D -m 0644 "$BRAND/cm-logo-text-version-64.png" \
    "$ROOTFS/usr/share/images/cybermyth/logo-text-version-64.png"

# --- Sweep: no Debian artwork may survive anywhere ---------------------------
# Filename/path sweep rather than a fixed list, so nothing is missed because a
# package moved a file. The manifest is what the audit compares against: these
# files keep their package-owned "debian" NAMES after we rewrite their CONTENTS,
# so counting filenames would flag the ones we just fixed.
step "Sweeping for remaining Debian artwork"
SWEPT=$(mktemp)
swept=0
while IFS= read -r f; do
    case "$f" in
        *.png)
            px=$(magick identify -format '%h' "$f" 2>/dev/null || echo 256)
            case "$px" in ''|*[!0-9]*) px=256 ;; esac
            [ "$px" -gt 1024 ] && px=1024
            magick "$BRAND/wolf-transparent.png" -resize x"$px" -background none \
                -gravity center -extent "${px}x${px}" "$f" 2>/dev/null || true
            printf '%s\n' "$f" >> "$SWEPT" ;;
        *.svg) svg_wrap "$BRAND/cm-logo-256.png" "$f" 2>/dev/null || true
            printf '%s\n' "$f" >> "$SWEPT" ;;
        *.jpg|*.jpeg)
            dim=$(magick identify -format '%wx%h' "$f" 2>/dev/null || echo 1920x1080)
            magick "$BRAND/cybermyth-bg.png" -resize "${dim}^" \
                -gravity center -extent "$dim" "$f" 2>/dev/null || true
            printf '%s\n' "$f" >> "$SWEPT" ;;
    esac
    swept=$((swept+1))
done < <(find "$ROOTFS/usr/share" "$ROOTFS/usr/local/share" -type f \
             \( -iname '*debian*.png' -o -iname '*debian*.svg' \
                -o -iname '*debian*.jpg' -o -iname '*debian*.jpeg' \) 2>/dev/null)
note "rewrote $swept Debian image file(s)"

# desktop-base theme wallpapers and login backgrounds -> CyberMyth background
while IFS= read -r f; do
    magick "$BRAND/cybermyth-bg.png" -resize 3072x2048 "$f" 2>/dev/null || true
done < <(find "$ROOTFS/usr/share/desktop-base" "$ROOTFS/usr/share/images/desktop-base" \
             -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null \
             | grep -viE 'debian-logos|emblem')

# --- Background picker -------------------------------------------------------
# The repo's gnome-backgrounds already removed GNOME's 24 wallpapers by being
# the same package at a higher version. desktop-base is the remaining source:
# it ships 10 more picker XMLs (debian-joy, debian-emerald, ...) and cannot be
# purged, because gnome-control-center Depends on it.
step "Restricting the background picker to CyberMyth"
GBP=/usr/share/gnome-background-properties
GBP_OFF=/var/lib/cybermyth/disabled-wallpapers
mkdir -p "$ROOTFS$GBP" "$ROOTFS$GBP_OFF"

# dpkg-divert, not rm: the CyberMyth repo is enabled in the image, so the first
# "apt upgrade" that refreshes desktop-base would put them straight back.
diverted=0
for x in "$ROOTFS$GBP"/*.xml; do
    [ -e "$x" ] || continue
    b=$(basename "$x")
    case "$b" in cybermyth*.xml) continue ;; esac
    chroot "$ROOTFS" dpkg-divert --local --rename \
        --divert "$GBP_OFF/$b" --add "$GBP/$b" >/dev/null 2>&1 || true
    rm -f "$ROOTFS$GBP_OFF/$b"
    diverted=$((diverted+1))
done
note "diverted $diverted third-party wallpaper list(s)"

# desktop-base ships its wallpapers, lockscreens and login backgrounds as SVG,
# which neither sweep above matched (the filename sweep only matches names
# containing "debian").
wp_removed=0
while IFS= read -r f; do
    rm -f "$f"; wp_removed=$((wp_removed+1))
done < <(find "$ROOTFS/usr/share/desktop-base" -type f -iname '*.svg' 2>/dev/null \
             | grep -viE 'debian-logos|emblem')
note "removed $wp_removed desktop-base wallpaper file(s)"

# Those wallpapers are reached through update-alternatives symlinks, not plain
# files. Having just deleted the targets, register ours above desktop-base's 70
# so the chain resolves to a real file instead of dangling. Never write to the
# symlink paths directly -- that would desync the alternatives database.
chroot "$ROOTFS" update-alternatives --install \
    /usr/share/images/desktop-base/desktop-background desktop-background \
    /usr/share/backgrounds/cybermyth.png 100 >/dev/null 2>&1 || true
chroot "$ROOTFS" update-alternatives --install \
    /usr/share/images/desktop-base/login-background.svg desktop-login-background \
    /usr/share/backgrounds/cybermyth.png 100 >/dev/null 2>&1 || true

if [ -d "$ROOTFS/usr/share/wallpapers" ]; then
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        [ -e "$l" ] || rm -f "$l"
    done < <(find "$ROOTFS/usr/share/wallpapers" -maxdepth 1 -type l 2>/dev/null || true)
fi
note "picker lists $(ls -1 "$ROOTFS$GBP"/*.xml 2>/dev/null | wc -l) wallpaper(s)"

# Default user avatar: the wolf. /etc/skel and the pixmap, since live-config
# creates the account at boot and there is no home directory yet.
install -D -m 0644 "$BRAND/cm-logo-256.png" "$ROOTFS/usr/share/pixmaps/faces/cybermyth.png"

# --- GNOME Shell extension ---------------------------------------------------
step "Installing the CyberMyth Shell extension"
EXTUUID=cybermyth-theme@cybermyth.dev
EXTDIR=$ROOTFS/usr/share/gnome-shell/extensions/$EXTUUID
mkdir -p "$EXTDIR"
unzip -q -o "$BRAND/cybermyth-theme.zip" -d "$EXTDIR"
[ -f "$EXTDIR/metadata.json" ] || die "extension did not unpack correctly"
find "$EXTDIR" -type d -exec chmod 0755 {} +
find "$EXTDIR" -type f -exec chmod 0644 {} +
note "installed $EXTUUID"

# --- Tilix theming -----------------------------------------------------------
# A system dconf default, so it holds for the live user AND any account
# Calamares creates later.
step "Configuring Tilix and VTE"
mkdir -p "$ROOTFS/etc/dconf/db/local.d" "$ROOTFS/etc/dconf/profile"
cat > "$ROOTFS/etc/dconf/profile/user" <<'EOF'
user-db:user
system-db:local
EOF
cat > "$ROOTFS/etc/dconf/db/local.d/01-cybermyth-tilix" <<'EOF'
[com/gexperts/Tilix/profiles/2b7c4080-0ddd-46c5-8f23-563fd3ba789d]
visible-name='CyberMyth'
use-theme-colors=false
foreground-color='#54FFFF'
background-color='#000000'
use-transparent-background=true
background-transparency-percent=30
cursor-colors-set=true
cursor-foreground-color='#000000'
cursor-background-color='#54FFFF'
palette-name='CyberMyth'

[com/gexperts/Tilix/settings]
theme-variant='dark'
EOF

# Tilix needs VTE's shell integration, and Debian ships that script versioned.
cat > "$ROOTFS/usr/local/sbin/cybermyth-vte-link" <<'VTE'
#!/bin/sh
# Point /etc/profile.d/vte.sh at the installed versioned VTE script.
set -eu
for v in /etc/profile.d/vte-*.sh; do
    [ -e "$v" ] || continue
    ln -sf "$v" /etc/profile.d/vte.sh
    exit 0
done
exit 0
VTE
chmod 0755 "$ROOTFS/usr/local/sbin/cybermyth-vte-link"

BASHRC_SNIPPET='
# Tilix / VTE shell integration
if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
        source /etc/profile.d/vte.sh
fi'
for rc in "$ROOTFS/etc/skel/.bashrc" "$ROOTFS/root/.bashrc"; do
    [ -f "$rc" ] || continue
    grep -q 'TILIX_ID' "$rc" || printf '%s\n' "$BASHRC_SNIPPET" >> "$rc"
done

# --- Calamares ---------------------------------------------------------------
step "Branding Calamares"
[ -d "$CALDIR" ] || die "missing $CALDIR -- it holds the CyberMyth Calamares overrides"
# branding/, settings.conf and the module overrides, laid over
# calamares-settings-debian's own files.
cp -a "$CALDIR/etc/calamares/." "$ROOTFS/etc/calamares/"
if [ -d "$CALDIR/usr" ]; then cp -a "$CALDIR/usr/." "$ROOTFS/usr/"; fi

# calamares-settings-debian's sources-final helper REWRITES the installed
# system's /etc/apt/sources.list -- and its version enables trixie-backports and
# drops contrib/non-free. Ours must win, and must survive an upgrade of that
# package, so divert rather than overwrite.
SF=/usr/share/calamares/helpers/calamares-sources-final
chroot "$ROOTFS" dpkg-divert --local --rename \
    --divert "$SF.debian" --add "$SF" >/dev/null 2>&1 || true
install -m 0755 "$CALDIR/helpers/calamares-sources-final" "$ROOTFS$SF"
# Two things must hold: the diverted file is OURS, and it enables no backports
# source. Match an actual uncommented deb/deb-src line -- an earlier revision of
# this check grepped for the word "backports" anywhere in the file and tripped
# on the helper's own comments explaining why backports are excluded.
if ! grep -q 'CyberMyth' "$ROOTFS$SF"; then
    die "$SF is not the CyberMyth helper -- the dpkg-divert did not take."
fi
if grep -qE '^[[:space:]]*deb(-src)?[[:space:]].*backports' "$ROOTFS$SF"; then
    printf '\n  offending line(s):\n'
    grep -nE '^[[:space:]]*deb(-src)?[[:space:]].*backports' "$ROOTFS$SF" | sed 's/^/    /'
    die "the sources-final helper would enable a backports source on installed systems"
fi
note "sources-final helper diverted (no backports on installed systems)"

# --- Every package Calamares removes must actually be installed --------------
# The packages module runs, literally:
#     apt-get --purge -q -y remove <names from packages.conf>
# in the TARGET root. apt resolves an installed package from dpkg's status file
# and needs no index -- but a name that is neither installed nor in any index is
# fatal (exit 100, "E: Unable to locate package X"), and Calamares reports it as
#     "Installation failed after bootloader installation finished."
#
# This ISO has no pool/ on the medium and mk-rootfs.sh empties
# /var/lib/apt/lists, so on a machine with no network during install apt knows
# ONLY what is installed. calamares-settings-debian's stock list names four
# packages this image never installs (live-boot-doc, live-config-doc,
# live-task-localisation, live-task-recommended) and that is exactly how the
# first ISO failed to install.
#
# Checked here, at build time, where it costs nothing.
step "Verifying Calamares' removal list against what is installed"
PKGCONF=$ROOTFS/etc/calamares/modules/packages.conf
[ -f "$PKGCONF" ] || die "no $PKGCONF -- the Calamares overrides did not land"
rmfail=0
rmnames=$(sed -nE "s/^[[:space:]]*- '([^']+)'.*/\1/p" "$PKGCONF")
[ -n "$rmnames" ] || die "could not parse any package names out of packages.conf"
for rp in $rmnames; do
    if chroot "$ROOTFS" dpkg-query -W -f='${Status}' "$rp" 2>/dev/null \
       | grep 'install ok installed' >/dev/null; then
        note "OK      $rp"
    else
        note "NOT INSTALLED  $rp"
        rmfail=$((rmfail+1))
    fi
done
[ "$rmfail" -eq 0 ] || die "$rmfail package(s) in packages.conf are not installed.
apt-get remove would exit 100 on them and the INSTALL would fail after the
bootloader step -- the live session would still boot fine, so this is only
discovered by actually installing. Remove them from
calamares/etc/calamares/modules/packages.conf."

# The launcher ships as calamares-install-debian.desktop; rename what the user
# sees without renaming the file the autostart entry points at.
DESK=$ROOTFS/usr/share/applications/calamares-install-debian.desktop
if [ -f "$DESK" ]; then
    sed -i -e "s|^Name=.*|Name=Install CyberMyth OS|" \
           -e "s|^GenericName=.*|GenericName=System Installer|" \
           -e "s|^Comment=.*|Comment=Install CyberMyth OS to this computer|" \
           -e "s|^Icon=.*|Icon=cybermyth|" \
           -e "s|^Keywords=.*|Keywords=calamares;system;install;cybermyth;installer;|" "$DESK"
    note "installer launcher rebranded"
fi
install -D -m 0755 "$DESK" "$ROOTFS/etc/skel/Desktop/calamares-install-debian.desktop" 2>/dev/null || true

# --- "Install CyberMyth OS" GRUB entry -> actually launching the installer ----
# calamares-settings-debian ships /etc/xdg/autostart/calamares-desktop-icon.desktop,
# but that only DROPS AN ICON on the desktop -- it never starts Calamares, and
# there is no calamares.autostart kernel parameter anywhere in the package. So
# the ISO's "Install" menu entry needs a mechanism of its own, or it would boot
# an identical live session and appear to do nothing.
#
# This autostart entry runs in every live session and exits immediately unless
# "cybermyth.install" is on the kernel command line, so the plain Live entry is
# completely unaffected.
cat > "$ROOTFS/usr/local/bin/cybermyth-install-autostart" <<'AUTO'
#!/bin/sh
# Launch Calamares when the ISO was booted from the "Install" menu entry.
set -eu
grep -qw 'cybermyth.install' /proc/cmdline || exit 0
# Give the shell a moment to finish laying out the session; Calamares opening
# before the panel exists leaves a window with no decorations on some setups.
sleep 5
exec calamares-install-debian
AUTO
chmod 0755 "$ROOTFS/usr/local/bin/cybermyth-install-autostart"

cat > "$ROOTFS/etc/xdg/autostart/cybermyth-install-autostart.desktop" <<'AUTOD'
[Desktop Entry]
Type=Application
Name=CyberMyth installer autostart
Exec=/usr/local/bin/cybermyth-install-autostart
StartupNotify=false
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
AUTOD
chmod 0644 "$ROOTFS/etc/xdg/autostart/cybermyth-install-autostart.desktop"
note "installer autostart wired to the cybermyth.install kernel parameter"

# --- Final chroot configuration ---------------------------------------------
step "Configuring inside the chroot"
chroot "$ROOTFS" /bin/bash -eu <<CHROOT
export DEBIAN_FRONTEND=noninteractive

# Extension schemas must be compiled or the extension silently fails to load.
EXTDIR=/usr/share/gnome-shell/extensions/cybermyth-theme@cybermyth.dev
if [ -d "\$EXTDIR/schemas" ]; then
    glib-compile-schemas "\$EXTDIR/schemas" && echo "compiled extension schemas"
fi
glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
/usr/local/sbin/cybermyth-vte-link || true
dconf update >/dev/null 2>&1 || true

# Point the GDM greeter at our logo, then rebuild the file-db it actually reads.
# Debian's gdm3 does NOT read /etc/dconf/db/gdm.d -- its profile names
# /var/lib/gdm3/greeter-dconf-defaults, compiled from /usr/share/gdm/dconf/.
if [ -f /etc/gdm3/greeter.dconf-defaults ]; then
    if grep -q '^[#[:space:]]*logo=' /etc/gdm3/greeter.dconf-defaults; then
        sed -i "s|^[#[:space:]]*logo=.*|logo='/usr/share/images/cybermyth/logo-text-version-64.png'|" \
            /etc/gdm3/greeter.dconf-defaults
    else
        printf "\n[org/gnome/login-screen]\nlogo='/usr/share/images/cybermyth/logo-text-version-64.png'\n" \
            >> /etc/gdm3/greeter.dconf-defaults
    fi
fi
mkdir -p /var/lib/gdm3
dconf compile /var/lib/gdm3/greeter-dconf-defaults /usr/share/gdm/dconf \
    && echo "compiled /var/lib/gdm3/greeter-dconf-defaults" \
    || echo "WARNING: gdm dconf compile failed"

# Do NOT swallow errors: if the theme fails to apply, plymouth falls back and
# the splash silently never appears.
plymouth-set-default-theme cybermyth
# Verify against what plymouthd ACTUALLY reads on Debian 13: /etc/plymouth/
# plymouthd.conf, which overrides /usr/share/plymouth/plymouthd.defaults (that
# ships Theme=ceratopsian). The /etc/alternatives/default.plymouth path an
# earlier revision echoed here is from an older plymouth and does not exist on
# trixie, so it reported nothing either way.
if grep -qx 'Theme=cybermyth' /etc/plymouth/plymouthd.conf; then
    echo "plymouth theme -> cybermyth"
else
    echo "ERROR: plymouthd.conf does not select the cybermyth theme:" >&2
    cat /etc/plymouth/plymouthd.conf >&2
    exit 1
fi

systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl enable gdm3.service           >/dev/null 2>&1 || true
systemctl set-default graphical.target  >/dev/null 2>&1 || true

# MODULES=most is Debian's default and the reason a Debian initramfs boots on
# arbitrary hardware. State it rather than inherit it -- this image has exactly
# one job, which is to boot on machines we have never seen.
mkdir -p /etc/initramfs-tools/conf.d
echo "MODULES=most" > /etc/initramfs-tools/conf.d/cybermyth-modules
echo "COMPRESS=zstd" >> /etc/initramfs-tools/conf.d/cybermyth-modules

depmod -a "$KREL"
update-initramfs -u -k "$KREL" || update-initramfs -c -k "$KREL"
CHROOT

[ -f "$ROOTFS/boot/initrd.img-$KREL" ] || die "initramfs was not generated for $KREL"

# live-boot's initramfs hook is what makes "boot=live" work at all. If it is
# missing the ISO boots to an initramfs prompt, so check rather than hope.
step "Verifying the initramfs"
# An earlier revision of this check was
#     lsinitramfs ... 2>/dev/null | grep -q 'scripts/live$'
# and reported a MISSING live script on an initramfs that demonstrably contained
# scripts/live, usr/lib/live/boot/9990-main.sh and the rest. The exact trigger
# was never reproduced -- and could not be, because that form threw away both
# lsinitramfs's exit status and its stderr, and 'set -o pipefail' made the
# pipeline's status depend on a process that had just been handed a closed pipe.
#
# So: no pipeline (nothing to misreport), and the diagnostics are kept.
# As a general rule in these scripts, prefer 'grep PATTERN >/dev/null' over
# 'grep -q' on the read end of a pipe: -q exits at the first match and can leave
# the writer with SIGPIPE, which under pipefail turns a match into a failure.
LSOUT=$(mktemp)
LSERR=$(mktemp)
# Capture the exit status and stderr instead of discarding them. The previous
# revision sent stderr to /dev/null, so when this check failed during a build
# there was no evidence left of WHY -- the listing itself was never in doubt.
lsrc=0
lsinitramfs "$ROOTFS/boot/initrd.img-$KREL" > "$LSOUT" 2> "$LSERR" || lsrc=$?
if [ "$lsrc" -ne 0 ] || [ ! -s "$LSOUT" ]; then
    printf '    lsinitramfs exit=%s, %s line(s) of output\n' "$lsrc" "$(wc -l < "$LSOUT")"
    if [ -s "$LSERR" ]; then sed 's/^/      stderr: /' "$LSERR"; fi
fi
ifail=0
for entry in scripts/live usr/lib/live/boot/9990-main.sh usr/lib/live/boot/9990-overlay.sh; do
    if grep -qx "$entry" "$LSOUT"; then
        note "OK      $entry"
    else
        note "MISSING $entry"
        ifail=$((ifail+1))
    fi
done
note "initramfs entries: $(wc -l < "$LSOUT")"
if [ "$ifail" -ne 0 ]; then
    printf '\n    every entry matching "live" in the initramfs:\n'
    grep -i live "$LSOUT" | sed 's/^/      /' | head -20
    printf '    lsinitramfs exit was %s\n' "$lsrc"
    if [ -s "$LSERR" ]; then sed 's/^/      stderr: /' "$LSERR"; fi
    rm -f "$LSOUT" "$LSERR"
    die "live-boot is not in the initramfs -- the ISO would not boot.
Check that live-boot-initramfs-tools is installed."
fi
rm -f "$LSOUT" "$LSERR" 
note "initramfs: $(du -h "$ROOTFS/boot/initrd.img-$KREL" | awk '{print $1}')"

# --- Cleanup -----------------------------------------------------------------
step "Cleaning up"
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
chroot "$ROOTFS" apt-get clean >/dev/null 2>&1 || true
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/archives/*.deb
rm -f  "$ROOTFS"/var/log/*.log "$ROOTFS"/var/log/apt/* 2>/dev/null || true
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/etc/resolv.conf"
ln -sf /run/NetworkManager/resolv.conf "$ROOTFS/etc/resolv.conf"
rm -f "$ROOTFS"/root/.bash_history "$ROOTFS"/home/*/.bash_history 2>/dev/null || true

# --- Unmount before auditing --------------------------------------------------
# Nothing below this point enters the chroot, and leaving /proc mounted makes
# every subsequent walk of the tree wrong: "du" descends into /proc and reports
# a bogus size against a directory whose contents change as it reads, printing
#     du: cannot read directory '.../rootfs/proc/65270/task/65270/net'
# The EXIT trap would eventually unmount these, but not until after the audit
# and the size report have already read them.
step "Unmounting pseudo-filesystems"
unmount_pseudo
for d in dev/pts dev proc sys run; do
    if mountpoint -q "$ROOTFS/$d" 2>/dev/null; then
        die "$ROOTFS/$d is still mounted -- mk-iso.sh would squash /proc into the image"
    fi
done
note "dev, dev/pts, proc, sys, run all unmounted"

# --- Audit -------------------------------------------------------------------
step "Branding audit"
fail=0
check() { if [ -e "$2" ]; then printf '    OK      %s\n' "$1"
          else printf '    MISSING %s\n' "$1"; fail=$((fail+1)); fi }

check "kernel"            "$ROOTFS/boot/vmlinuz-$KREL"
check "initramfs"         "$ROOTFS/boot/initrd.img-$KREL"
check "modules"           "$ROOTFS/lib/modules/$KREL"
check "gdm3"              "$ROOTFS/usr/sbin/gdm3"
check "calamares"         "$ROOTFS/usr/bin/calamares"
check "calamares branding" "$ROOTFS/etc/calamares/branding/cybermyth/branding.desc"
check "wallpaper"         "$ROOTFS/usr/share/backgrounds/cybermyth.png"
check "plymouth theme"    "$ROOTFS/usr/share/plymouth/themes/cybermyth/cybermyth.plymouth"
check "shell extension"   "$ROOTFS/usr/share/gnome-shell/extensions/cybermyth-theme@cybermyth.dev/metadata.json"
check "extension schema"  "$ROOTFS/usr/share/gnome-shell/extensions/cybermyth-theme@cybermyth.dev/schemas/gschemas.compiled"
check "live-config conf"  "$ROOTFS/etc/live/config.conf"
check "live password cmp" "$ROOTFS/usr/lib/live/config/0035-cybermyth-password"
check "gdm greeter db"    "$ROOTFS/var/lib/gdm3/greeter-dconf-defaults"
check "tor-browser"       "$ROOTFS/opt/tor-browser/Browser/start-tor-browser"

find "$ROOTFS/usr/share" "$ROOTFS/usr/local/share" -type f \
    \( -iname '*debian*.png' -o -iname '*debian*.svg' -o -iname '*debian*.jpg' \) \
    2>/dev/null | sort -u > "$SWEPT.found"
sort -u "$SWEPT" > "$SWEPT.done" 2>/dev/null || : > "$SWEPT.done"
leftover=$(comm -23 "$SWEPT.found" "$SWEPT.done" | wc -l)
printf '    Debian-named images: %s total, %s rewritten, %s NOT rewritten\n' \
    "$(wc -l < "$SWEPT.found")" "$(wc -l < "$SWEPT.done")" "$leftover"
if [ "$leftover" -gt 0 ]; then
    comm -23 "$SWEPT.found" "$SWEPT.done" | sed 's|^|      MISSED |' | head -10
fi

# ID_LIKE=debian is deliberate: it is how software detects a Debian base.
resid=$(cat "$ROOTFS/usr/lib/os-release" "$ROOTFS/etc/issue" "$ROOTFS/etc/issue.net" \
        "$ROOTFS/etc/lsb-release" "$ROOTFS/etc/motd" 2>/dev/null \
        | grep -i 'debian' | grep -vc '^ID_LIKE=' || true)
printf '    user-visible Debian strings (ID_LIKE excluded): %s\n' "$resid"
if [ "$leftover" -ne 0 ] || [ "$resid" -ne 0 ]; then
    printf '    WARNING: branding leftovers detected (listed above)\n'
    fail=$((fail+1))
fi

rm -f "$SWEPT" "$SWEPT.found" "$SWEPT.done"

printf '\n    os-release:\n'; sed 's/^/      /' "$ROOTFS/usr/lib/os-release"

[ "$fail" -eq 0 ] || die "$fail audit failure(s) -- refusing to report success"
mark_stage ROOTFS_DONE

step "Result"
printf '    rootfs : %s (%s)\n' "$ROOTFS" "$(du -sh "$ROOTFS" | awk '{print $1}')"
printf '    kernel : %s\n' "$KREL"
printf '    live   : %s / %s   hostname %s\n' "$LIVE_USER" "$LIVE_PASS" "$HOSTNAME"
printf '\n    Next:  sudo %s/mk-iso.sh\n' "$HERE"
