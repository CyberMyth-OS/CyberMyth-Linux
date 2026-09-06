#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Toshith Yadav
#
# Build the CyberMyth OS amd64 live ISO from ./rootfs.
#
#   sudo ./mk-iso.sh [--clean]
#
# Boots BOTH legacy BIOS and UEFI x64.
#
# It was UEFI-only until 2026-09-06. That is fine on real hardware but fails in
# the place a reviewer is most likely to try it: a default VirtualBox/QEMU VM
# boots in BIOS mode and simply reports "no bootable medium". DistroWatch will
# not list a project they cannot get working, so the BIOS path is not optional.
#
# Secure Boot must still be DISABLED -- the kernel is signed by a key that is in
# no firmware db. shim + MOK enrolment is a later build.
#
# ISO layout (the paths are not arbitrary):
#   /live/filesystem.squashfs  <- calamares-settings-debian's unpackfs.conf reads
#                                 exactly /run/live/medium/live/filesystem.squashfs
#   /live/vmlinuz /live/initrd.img
#   /boot/grub/grub.cfg        <- the visible menu, editable without rebuilding
#                                 the EFI binary
#   /boot/grub/bios.img        <- BIOS El Torito image (grub-mkimage i386-pc-eltorito)
#   /boot/grub/i386-pc/*.mod   <- BIOS runtime modules; the core image cannot
#                                 embed them, see the note where it is built
#   (appended partition 2)     <- FAT ESP holding EFI/BOOT/BOOTX64.EFI, added by
#                                 xorriso as a GPT EFI System partition. It is
#                                 NOT a file in the ISO tree.
#   /.disk/cybermyth.id        <- the marker GRUB searches for to find its root

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOTFS=${ROOTFS:-$HERE/rootfs}
WORK=${WORK:-$HERE/iso-work}
BRAND=$HERE/branding

KREL=6.18.49-cybermyth-amd64
LABEL=${LABEL:-CYBERMYTH}
OS_NAME="CyberMyth OS"
OS_VERSION="1.0"
OUT=${OUT:-$HERE/cybermyth-${OS_VERSION}-amd64.iso}
COMP=${COMP:-zstd}

# Kernel command line for the live session.
#
# module.sig_enforce is deliberately ABSENT. An earlier revision of this script
# set it, which would reject every DKMS module -- the out-of-tree Realtek
# drivers, VirtualBox, nvidia -- on a distro whose whole point is loading them.
# CONFIG_MODULE_SIG_FORCE is off in the kernel for the same reason.
LIVE_CMDLINE="boot=live components quiet splash"
SAFE_CMDLINE="boot=live components nomodeset"

die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo $0)"

# --- Guard the work directory ------------------------------------------------
# This script rm -rf's $WORK. Refuse anything that is not a deep, non-symlink,
# non-system path, so a mistyped WORK= cannot delete something that matters.
assert_safe() {
    local p=$1 name=$2 real parent depth
    [ -n "$p" ] || die "$name is empty"
    case "$p" in /*) ;; *) die "$name must be absolute: $p" ;; esac
    [ "$p" != "/" ] || die "$name is '/'"
    [ ! -L "$p" ]   || die "$name is a symlink: $p"
    parent=$(dirname "$p")
    [ -d "$parent" ] || die "parent does not exist: $parent"
    real=$(cd "$parent" && pwd -P)
    [ "$real" = "/" ] && real=""
    real="$real/$(basename "$p")"
    depth=$(printf '%s' "${real#/}" | tr -cd '/' | wc -c)
    [ "$depth" -ge 2 ] || die "$name too shallow: $real"
    case "$real" in
        /|/bin*|/boot*|/dev*|/etc*|/home|/lib*|/proc*|/root*|/run*|/sbin*|/srv*|/sys*|/tmp|/usr*|/var*)
            die "$name is a system location: $real" ;;
    esac
    printf '%s' "$real"
}
WORK=$(assert_safe "$WORK" WORK)

if [ "${1:-}" = "--clean" ]; then
    step "Removing $WORK"
    rm -rf "$WORK"
    exit 0
fi

# --- Preflight ---------------------------------------------------------------
step "Preflight"
for t in xorriso mksquashfs grub-mkstandalone grub-mkimage grub-file mkfs.vfat mmd mcopy; do
    command -v "$t" >/dev/null 2>&1 \
        || die "missing host tool: $t
    apt install -y xorriso squashfs-tools grub-efi-amd64-bin grub-pc-bin dosfstools mtools"
done

# BIOS boot needs the i386-pc target, which lives in a DIFFERENT package from the
# EFI one (grub-pc-bin vs grub-efi-amd64-bin). Missing it silently loses the BIOS
# boot path, so check for the two files actually used rather than the directory.
GRUBBIOS=/usr/lib/grub/i386-pc
for f in "$GRUBBIOS/cdboot.img" "$GRUBBIOS/boot_hybrid.img"; do
    [ -f "$f" ] || die "missing $f -- the ISO would have no legacy BIOS boot path.
    apt install -y grub-pc-bin"
done

[ -d "$ROOTFS" ] || die "no rootfs at $ROOTFS -- run mk-rootfs.sh first"
[ -f "$ROOTFS/boot/vmlinuz-$KREL" ] || die "no kernel in the rootfs: /boot/vmlinuz-$KREL"
[ -f "$ROOTFS/boot/initrd.img-$KREL" ] || die "no initramfs in the rootfs: /boot/initrd.img-$KREL"
[ -f "$ROOTFS/usr/bin/calamares" ] || die "calamares is not in the rootfs"
[ -f "$ROOTFS/etc/calamares/branding/cybermyth/branding.desc" ] \
    || die "CyberMyth Calamares branding is not in the rootfs"

GRUBMODS=/usr/lib/grub/x86_64-efi
[ -d "$GRUBMODS" ] || die "missing GRUB EFI modules: $GRUBMODS
    apt install -y grub-efi-amd64-bin"

# The rootfs must not still be mounted from a failed mk-rootfs.sh run, or
# mksquashfs would capture /proc and /sys.
for d in dev/pts dev proc sys run; do
    if mountpoint -q "$ROOTFS/$d"; then
        die "$ROOTFS/$d is still mounted -- unmount it before squashing:
    umount -l $ROOTFS/$d"
    fi
done
note "rootfs: $(du -sh "$ROOTFS" | awk '{print $1}')"

ISO=$WORK/iso
mkdir -p "$ISO/live" "$ISO/boot/grub" "$ISO/EFI/boot" "$ISO/.disk"

# --- Kernel and initramfs ----------------------------------------------------
step "Staging kernel and initramfs"
install -m 0644 "$ROOTFS/boot/vmlinuz-$KREL"    "$ISO/live/vmlinuz"
install -m 0644 "$ROOTFS/boot/initrd.img-$KREL" "$ISO/live/initrd.img"
note "vmlinuz    $(du -h "$ISO/live/vmlinuz" | awk '{print $1}')"
note "initrd.img $(du -h "$ISO/live/initrd.img" | awk '{print $1}')"

# --- squashfs ----------------------------------------------------------------
# Rebuilt only when the rootfs is newer, because this is the slow step.
step "Building the squashfs"
SQFS=$ISO/live/filesystem.squashfs
if [ -f "$SQFS" ] && [ "$SQFS" -nt "$ROOTFS/etc/os-release" ]; then
    note "up to date -- delete $SQFS to force a rebuild"
else
    rm -f "$SQFS"
    # -wildcards with -e: exclusions are relative to the source root.
    # /boot stays IN: Calamares unpacks this squashfs as the installed system,
    # which needs its own kernel and initramfs.
    mksquashfs "$ROOTFS" "$SQFS" \
        -comp "$COMP" -Xcompression-level 19 \
        -b 1M -noappend -no-recovery -wildcards \
        -e 'proc/*' 'sys/*' 'dev/pts/*' 'run/*' 'tmp/*' \
           'var/cache/apt/archives/*.deb' 'var/lib/apt/lists/*' \
           'root/.bash_history' 'var/log/*' \
        || die "mksquashfs failed"
fi
printf '%s' "$(du -sb "$ROOTFS" | awk '{print $1}')" > "$ISO/live/filesystem.size"
note "squashfs: $(du -h "$SQFS" | awk '{print $1}')"

# --- Disk identity -----------------------------------------------------------
# GRUB finds its own root by searching for this file, so it works whether the
# ISO was burned, dd'd to USB, or attached as a virtual CD.
printf 'CYBERMYTH-LIVE-%s\n' "$OS_VERSION" > "$ISO/.disk/cybermyth.id"
printf '%s %s amd64 live\n' "$OS_NAME" "$OS_VERSION" > "$ISO/.disk/info"

# --- GRUB menu ---------------------------------------------------------------
step "Writing the GRUB menu"
install -D -m 0644 /usr/share/grub/unicode.pf2 "$ISO/boot/grub/fonts/unicode.pf2"
# The background is the CyberMyth wallpaper, flattened to 1024x768 PNG. GRUB's
# png module handles 24-bit RGB; an alpha channel renders as garbage on some
# firmware, so composite onto the solid ground colour rather than keeping it.
magick "$BRAND/cybermyth-bg.png" -resize 1024x768^ -gravity center \
       -extent 1024x768 -background '#0a0d10' -alpha remove -alpha off \
       -define png:color-type=2 "$ISO/boot/grub/cybermyth-bg.png" \
    || die "failed to render the GRUB background"

cat > "$ISO/boot/grub/grub.cfg" <<EOF
# CyberMyth OS $OS_VERSION -- amd64 live ISO
# UEFI x64 only. Secure Boot must be disabled: the kernel is signed by a key
# that is in no firmware db.

set default=0
set timeout=10

insmod all_video
insmod gfxterm
insmod png
insmod part_gpt
insmod iso9660

set gfxmode=auto
terminal_output gfxterm

loadfont \$prefix/fonts/unicode.pf2
background_image \$prefix/cybermyth-bg.png

set color_normal=cyan/black
set color_highlight=black/cyan

menuentry "$OS_NAME $OS_VERSION (Live)" --class cybermyth {
    linux  /live/vmlinuz $LIVE_CMDLINE
    initrd /live/initrd.img
}

menuentry "Install $OS_NAME $OS_VERSION" --class cybermyth {
    # Boots the same live session and starts Calamares straight away.
    # "cybermyth.install" is read by /usr/local/bin/cybermyth-install-autostart,
    # which mk-rootfs.sh installs. It is NOT a calamares or live-config
    # parameter -- neither package has one; Debian's autostart entry only drops
    # a desktop icon. The desktop comes up either way, so if the autostart fails
    # this degrades to the normal Live session rather than to nothing.
    linux  /live/vmlinuz $LIVE_CMDLINE cybermyth.install
    initrd /live/initrd.img
}

menuentry "$OS_NAME $OS_VERSION (safe graphics)" --class cybermyth {
    linux  /live/vmlinuz $SAFE_CMDLINE
    initrd /live/initrd.img
}
EOF
note "menu: Live (default) + Install + safe graphics"

# --- EFI boot image ----------------------------------------------------------
step "Building BOOTX64.EFI"
# The embedded config does nothing but find the ISO and hand over to the real
# grub.cfg above, so the menu can be edited without regenerating this binary.
# Modules are embedded rather than loaded from the ISO: at this point $prefix is
# not yet known, so an insmod of anything not already inside would fail.
EMBED=$(mktemp)
cat > "$EMBED" <<'CFG'
search --no-floppy --file --set=root /.disk/cybermyth.id
set prefix=($root)/boot/grub
configfile ($root)/boot/grub/grub.cfg
CFG

grub-mkstandalone \
    --format=x86_64-efi \
    --directory="$GRUBMODS" \
    --modules="part_gpt part_msdos fat iso9660 search search_fs_file search_fs_uuid search_label normal linux linux16 configfile echo test true boot chain gfxterm gfxmenu all_video video videoinfo png gzio loadenv minicmd reboot halt ls cat help terminal font" \
    --fonts="unicode" \
    --output="$ISO/EFI/boot/bootx64.efi" \
    "boot/grub/grub.cfg=$EMBED" \
    || die "grub-mkstandalone failed"
# Kept, not deleted: the BIOS core image below embeds the same handover config.
EMBED_BIOS=$EMBED

grub-file --is-x86_64-efi "$ISO/EFI/boot/bootx64.efi" \
    || die "the generated loader is not a valid x86_64 EFI program"
note "bootx64.efi: $(du -h "$ISO/EFI/boot/bootx64.efi" | awk '{print $1}')"

# --- BIOS boot image ---------------------------------------------------------
# grub-mkIMAGE, not grub-mkSTANDALONE. mkstandalone embeds every module plus a
# font into a memdisk, and the i386-pc core image has a hard 0x78000 (480 KiB)
# ceiling that a standalone build blows straight through:
#     grub-mkstandalone: error: core image is too big (0x2f87de > 0x78000)
# So the core carries only what it needs to find the ISO and read the real
# grub.cfg, and the remaining modules are shipped on the ISO at
# /boot/grub/i386-pc/ where GRUB can insmod them at runtime. That directory is
# NOT optional -- without it the BIOS menu loses gfxterm, png and all_video, and
# the branded background silently degrades to a plain text menu.
step "Building the BIOS boot image"
BIOSIMG=$ISO/boot/grub/bios.img
grub-mkimage \
    --format=i386-pc-eltorito \
    --directory="$GRUBBIOS" \
    --prefix=/boot/grub \
    --config="$EMBED_BIOS" \
    --output="$BIOSIMG" \
    biosdisk iso9660 part_msdos part_gpt search search_fs_file normal configfile echo \
    || die "grub-mkimage failed for the BIOS core image"

# 0x78000 = 491520. Check rather than trust: an oversized core image is written
# happily by some grub versions and then simply fails to boot.
BIOSSZ=$(stat -c %s "$BIOSIMG")
[ "$BIOSSZ" -lt 491520 ] \
    || die "BIOS core image is $BIOSSZ bytes, over the 491520 limit -- trim its module list"
mkdir -p "$ISO/boot/grub/i386-pc"
cp "$GRUBBIOS"/*.mod "$GRUBBIOS"/*.lst "$ISO/boot/grub/i386-pc/" 2>/dev/null || true
note "bios.img: $BIOSSZ bytes, plus $(ls "$ISO/boot/grub/i386-pc" | wc -l) runtime modules"

# --- FAT ESP image -----------------------------------------------------------
# This is what the El Torito EFI entry and the GPT both point at. It must be a
# real FAT filesystem; firmware will not read an ISO9660 copy in that role.
#
# Built OUTSIDE the ISO tree, in $WORK. xorriso APPENDS it to the image as
# partition 2, so putting it in the tree as well would store the same 4 MiB
# twice. (An earlier revision kept it at $ISO/boot/grub/efi.img and referenced
# it with -e boot/grub/efi.img; that works too, but duplicates it.)
step "Building the EFI System Partition image"
EFIIMG=$WORK/efi.img
rm -f "$EFIIMG"
# Earlier revisions built it at $ISO/boot/grub/efi.img. $WORK is reused between
# runs, so drop any leftover there or it would be carried into the ISO as a
# stray 4 MiB file that nothing references.
rm -f "$ISO/boot/grub/efi.img"
# Size it from the loader plus FAT overhead, rounded up to a whole number of
# 32 KiB blocks, with a floor of 4 MiB -- mkfs.vfat rejects tiny geometries and
# a fixed size would silently overflow if the loader grows.
EFISZ=$(( ( $(stat -c %s "$ISO/EFI/boot/bootx64.efi") / 1024 + 2048 ) / 32 * 32 ))
[ "$EFISZ" -lt 4096 ] && EFISZ=4096
mkfs.vfat -C -F 12 -n CMEFI "$EFIIMG" "$EFISZ" >/dev/null \
    || die "mkfs.vfat failed for the ESP image"
# mmd/mcopy rather than a loop mount: no privileged mount, no cleanup to get
# wrong, and it works identically inside a container.
export MTOOLS_SKIP_CHECK=1
mmd  -i "$EFIIMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFIIMG" "$ISO/EFI/boot/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI
mdir -i "$EFIIMG" ::/EFI/BOOT | sed 's/^/    /'
note "efi.img: ${EFISZ} KiB"

# --- ISO ---------------------------------------------------------------------
step "Building the ISO"
rm -f "$OUT"
# -append_partition 2 <ESP GUID> : adds the FAT image to the end of the ISO as a
#     real GPT partition typed C12A7328-F81F-11D2-BA4B-00A0C93EC93B (EFI System).
#     This is what firmware looks for when the image is dd'd to a USB stick.
# -appended_part_as_gpt : emit a GPT (with a protective MBR) describing it.
# -e --interval:appended_partition_2:all:: : point the El Torito EFI entry AT
#     that appended partition, so optical/virtual-CD boot uses the same bytes
#     and the ESP is stored exactly once.
#
# NOTE: -isohybrid-gpt-basdat does NOT work here and was the bug in an earlier
# revision. It belongs to xorriso's isohybrid/isolinux machinery and is a no-op
# without -isohybrid-mbr, which this UEFI-only image does not use. It failed
# SILENTLY: xorriso reported success and produced an ISO with no partition table
# at all -- bootable as a virtual CD, dead from USB.
#
# -append_partition takes a FILESYSTEM path, not an ISO-relative one.
# No -b/-isohybrid-mbr: there is no BIOS boot path in this image.
# Boot entry ORDER matters: El Torito holds the BIOS entry first, then
# -eltorito-alt-boot starts a second section for the UEFI one. Firmware picks
# the entry matching its own platform, so both coexist on one image.
#
#   -b boot/grub/bios.img -no-emul-boot -boot-load-size 4 -boot-info-table
#       the BIOS entry. -boot-info-table patches a table into the image, and
#       --grub2-boot-info makes xorriso write the GRUB2 variant of it.
#   --grub2-mbr .../boot_hybrid.img
#       the hybrid MBR, which is what lets a BIOS machine boot the ISO after it
#       has been dd'd to a USB stick. Without it the BIOS entry works only from
#       optical/virtual-CD media.
#   -append_partition 2 <ESP GUID> + -appended_part_as_gpt
#       the UEFI side, unchanged.
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -joliet -joliet-long \
    -rational-rock \
    -volid "$LABEL" \
    -appid "$OS_NAME $OS_VERSION" \
    -publisher "CyberMyth OS <repo@cybermyth.dev>" \
    -b boot/grub/bios.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --grub2-boot-info \
    --grub2-mbr "$GRUBBIOS/boot_hybrid.img" \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:all::' \
    -no-emul-boot \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$EFIIMG" \
    -appended_part_as_gpt \
    -output "$OUT" \
    "$ISO" || die "xorriso failed"

# --- Verify ------------------------------------------------------------------
step "Verifying the ISO"
fail=0
v() { if [ "$1" = 0 ]; then printf '    OK      %s\n' "$2"
      else printf '    FAILED  %s\n' "$2"; fail=$((fail+1)); fi }

xorriso -indev "$OUT" -find /live/filesystem.squashfs >/dev/null 2>&1; v $? "live/filesystem.squashfs present"
xorriso -indev "$OUT" -find /live/vmlinuz            >/dev/null 2>&1; v $? "live/vmlinuz present"
xorriso -indev "$OUT" -find /live/initrd.img         >/dev/null 2>&1; v $? "live/initrd.img present"
xorriso -indev "$OUT" -find /boot/grub/grub.cfg      >/dev/null 2>&1; v $? "boot/grub/grub.cfg present"
# NOT checked in the ISO tree any more: the ESP is the APPENDED partition,
# verified below against the GPT rather than as a file.
xorriso -indev "$OUT" -find /EFI/boot/bootx64.efi    >/dev/null 2>&1; v $? "EFI/boot/bootx64.efi present"
xorriso -indev "$OUT" -find /.disk/cybermyth.id      >/dev/null 2>&1; v $? ".disk/cybermyth.id present"

# The GPT is what makes a dd'd USB stick bootable on UEFI. Without it the ISO
# still boots as a virtual CD and fails from USB, which is a miserable thing to
# discover on someone else's laptop.
#
# Asked of xorriso, not fdisk: xorriso is already a hard requirement of this
# script, whereas fdisk lives in /sbin and may not be on PATH -- and the earlier
# form piped fdisk's output with stderr discarded, so a missing fdisk would have
# looked exactly like a missing partition.
#
# 28732ac11ff8d211ba4b00a0c93ec93b is C12A7328-F81F-11D2-BA4B-00A0C93EC93B, the
# EFI System Partition type GUID, as xorriso prints it (mixed-endian, no dashes).
SAREA=$(mktemp)
xorriso -indev "$OUT" -report_system_area plain > "$SAREA" 2>/dev/null || true

if grep -q 'protective-msdos-label' "$SAREA"; then
    printf '    OK      protective MBR present\n'
else
    printf '    FAILED  no protective MBR\n'; fail=$((fail+1))
fi
if grep -q '^System area summary:.*GPT' "$SAREA"; then
    printf '    OK      GPT present\n'
else
    printf '    FAILED  no GPT -- the ISO would not boot from a USB stick\n'; fail=$((fail+1))
fi
if grep -qi '^GPT type GUID *: *[0-9]* *28732ac11ff8d211ba4b00a0c93ec93b' "$SAREA"; then
    espn=$(awk '/^GPT type GUID/ && $NF=="28732ac11ff8d211ba4b00a0c93ec93b" {print $5}' "$SAREA")
    # Field offsets differ between the two lines xorriso prints:
    #   GPT type GUID      :   2  28732ac1...   -> partition is $5
    #   GPT start and size :   2  8724  8192    -> partition is $6, size is $8
    espsz=$(awk -v n="$espn" '/^GPT start and size/ && $6==n {print $8}' "$SAREA")
    printf '    OK      GPT partition %s is an EFI System partition (%s sectors)\n' \
        "$espn" "${espsz:-?}"
else
    printf '    FAILED  no EFI System partition in the GPT\n'
    sed 's/^/              /' "$SAREA" | head -20
    fail=$((fail+1))
fi

# Both El Torito platforms must be present. Written to a file and grepped there:
# see the SIGPIPE note in mk-rootfs.sh about grep -q on the read end of a pipe.
ELT=$(mktemp)
xorriso -indev "$OUT" -report_el_torito plain > "$ELT" 2>/dev/null || true
for plat in BIOS UEFI; do
    if grep 'El Torito boot img' "$ELT" | grep "$plat" >/dev/null; then
        printf '    OK      El Torito has a %s boot image\n' "$plat"
    else
        printf '    FAILED  no %s El Torito boot image\n' "$plat"; fail=$((fail+1))
    fi
done
rm -f "$ELT"

# The hybrid MBR is what makes the BIOS path work from a dd'd USB stick rather
# than only from optical media.
if grep -q 'grub2-mbr' "$SAREA"; then
    printf '    OK      GRUB2 hybrid MBR installed (BIOS boot from USB)\n'
else
    printf '    FAILED  no GRUB2 hybrid MBR -- BIOS boot would fail from USB\n'
    fail=$((fail+1))
fi
rm -f "$SAREA"

[ "$fail" -eq 0 ] || die "$fail ISO check(s) failed"

( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
chown --reference="$HERE" "$OUT" "$OUT.sha256" 2>/dev/null || true

step "Result"
printf '    ISO    : %s (%s)\n' "$OUT" "$(du -h "$OUT" | awk '{print $1}')"
printf '    label  : %s\n' "$LABEL"
printf '    kernel : %s\n' "$KREL"
printf '    sha256 : %s\n' "$(awk '{print $1}' "$OUT.sha256")"
printf '\n    Write it to a USB stick with:\n'
printf '      sudo dd if=%s of=/dev/sdX bs=4M status=progress oflag=sync\n' "$OUT"
printf '\n    Secure Boot must be DISABLED in firmware.\n'
