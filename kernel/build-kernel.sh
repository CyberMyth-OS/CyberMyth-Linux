#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Toshith Yadav
# Build the CyberMyth OS kernel for amd64 as Debian packages.
#
# Produces, in ../pkg/:
#   linux-image-6.18.49-cybermyth-amd64_6.18.49-1cybermyth1_amd64.deb
#   linux-headers-6.18.49-cybermyth-amd64_6.18.49-1cybermyth1_amd64.deb
#   linux-image-6.18.49-cybermyth-amd64-dbg_...  (NOT shipped on the ISO)
#   linux-libc-dev_...                           (NOT shipped -- Debian owns it)
#
# Runs entirely unprivileged: bindeb-pkg builds under fakeroot.
#
# Config lineage, in order:
#   1. Debian 13's own amd64 config from /boot  -- the "compatible like Debian 13"
#      guarantee. Debian 13 ships a 6.12 kernel, so olddefconfig resolves the
#      6.12 -> 6.18 symbol drift using upstream defaults, exactly as Debian does
#      when it rebases.
#   2. cybermyth-wireless.fragment  -- the drivers Debian's 6.12 config predates.
#   3. cybermyth-hardening.fragment -- the security posture.
#   4. cybermyth-brand.fragment     -- identity, and BTF kept on.
#
# Usage:
#   ./build-kernel.sh              build (resumes; reuses an existing .config)
#   ./build-kernel.sh --reconfig   regenerate .config from scratch, then build
#   ./build-kernel.sh --config-only  generate and verify .config, do not compile

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE=$(dirname "$HERE")
LINUX=$BASE/linux-6.18.49
PKGDIR=$BASE/pkg
STAGED=$HERE/staged

KVER=6.18.49
FLAVOUR=cybermyth-amd64
KREL=$KVER-$FLAVOUR
PKGVERSION=${PKGVERSION:-$KVER-1cybermyth1}
SRCNAME=linux-cybermyth
JOBS=${JOBS:-$(nproc)}

die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }

RECONFIG=0; CONFIG_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --reconfig)    RECONFIG=1 ;;
        --config-only) CONFIG_ONLY=1; RECONFIG=1 ;;
        -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || die "do NOT run this as root -- bindeb-pkg uses fakeroot,
and a root-owned object tree makes the later unprivileged stages fail."
[ -f "$LINUX/Makefile" ] || die "kernel tree not found: $LINUX"

# Refuse to build the wrong tree rather than discover it in the package name.
tree_ver=$(make -s -C "$LINUX" kernelversion 2>/dev/null || echo "")
[ "$tree_ver" = "$KVER" ] || die "kernel tree is $tree_ver, expected $KVER"

mkdir -p "$PKGDIR" "$STAGED"

# --- Base config -------------------------------------------------------------
# Newest Debian amd64 config on this host. Sorting with -V so 6.12.105 beats
# 6.12.99; a plain glob sorts those the other way round.
BASECFG=$(ls -1 /boot/config-*-amd64 2>/dev/null | sort -V | tail -1)
[ -n "$BASECFG" ] || die "no Debian amd64 config found in /boot -- install linux-image-amd64"

if [ "$RECONFIG" -eq 1 ] || [ ! -f "$LINUX/.config" ]; then
    step "Generating .config"
    note "base: $BASECFG"
    cp "$BASECFG" "$LINUX/.config"

    # Resolve the 6.12 -> 6.18 drift first, so the fragments merge onto a config
    # that is already internally consistent for THIS tree.
    make -s -C "$LINUX" LOCALVERSION= olddefconfig
    cp "$LINUX/.config" "$STAGED/config-01-debian-olddefconfig"
    note "after olddefconfig: $(grep -c '=[ym]$' "$LINUX/.config") symbols set"

    # merge_config.sh -m merges without invoking a config target, so all three
    # fragments land before anything is resolved. It prints a warning for every
    # value it overrides -- captured here rather than left to scroll past.
    step "Merging CyberMyth fragments"
    ( cd "$LINUX" && ./scripts/kconfig/merge_config.sh -m -O . .config \
        "$HERE/cybermyth-wireless.fragment" \
        "$HERE/cybermyth-hardening.fragment" \
        "$HERE/cybermyth-brand.fragment" ) 2>&1 | sed 's/^/  /'

    make -s -C "$LINUX" LOCALVERSION= olddefconfig
    cp "$LINUX/.config" "$STAGED/config-02-cybermyth-merged"
fi

# --- Verify the config actually says what the fragments asked for -------------
# merge_config warns on conflicts but exits 0, and olddefconfig will silently
# drop any symbol whose dependencies are unmet. Neither shows up until the
# finished kernel is missing a driver, so check every request explicitly.
step "Verifying merged config"
CFG=$LINUX/.config
bad=0

want() {  # want SYMBOL EXPECTED_VALUE
    local sym=$1 want=$2 got
    if got=$(grep -E "^CONFIG_$sym=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2-); then :; fi
    [ -z "${got:-}" ] && grep -q "^# CONFIG_$sym is not set" "$CFG" 2>/dev/null && got="n"
    [ -z "${got:-}" ] && got="<absent>"
    if [ "$got" = "$want" ]; then
        printf '  OK    %-34s %s\n' "$sym" "$got"
    else
        printf '  FAIL  %-34s want %-22s got %s\n' "$sym" "$want" "$got"
        bad=$((bad+1))
    fi
}

printf '\n  -- identity --\n'
want LOCALVERSION '"-cybermyth-amd64"'
want LOCALVERSION_AUTO n
want DEFAULT_HOSTNAME '"cybermyth"'

printf '\n  -- hardening (the deltas from Debian) --\n'
want INIT_ON_FREE_DEFAULT_ON y
want RANDOM_KMALLOC_CACHES y
want ZERO_CALL_USED_REGS y
want INIT_ON_ALLOC_DEFAULT_ON y
want SLAB_FREELIST_RANDOM y
want SLAB_FREELIST_HARDENED y
want HARDENED_USERCOPY y
want VMAP_STACK y
want STACKPROTECTOR_STRONG y
want RANDOMIZE_BASE y
want LEGACY_VSYSCALL_NONE y
want SECURITY_DMESG_RESTRICT y
want BPF_UNPRIV_DEFAULT_OFF y
want SECURITY_APPARMOR y
want SECURITY_LANDLOCK y
want MODULE_SIG y
want MODULE_SIG_ALL y
want MODULE_SIG_FORCE n
want LSM '"landlock,yama,integrity,apparmor,bpf"'

printf '\n  -- left at Debian defaults on purpose --\n'
want HIBERNATION y
want KEXEC y
want KEXEC_FILE y
want DEBUG_INFO_BTF y

printf '\n  -- wireless additions --\n'
want RTW88_8812AU m
want RTW88_8814AU m
want RTW88_8814AE m
want RTW88_8821AU m
want RTW89_8851BU m
want RTW89_8852BU m
want IWLMLD m
# promptless, pulled in by select -- verify the select actually fired
want RTW88_88XXA m
want RTW89_USB m

printf '\n  -- netfilter for the transparent-Tor killswitch --\n'
want NF_TABLES y
want NFT_TPROXY m
want NFT_REDIR m
want NFT_SOCKET m

printf '\n  -- lockdown must NOT be in the LSM order --\n'
if grep -q '^CONFIG_LSM=.*lockdown' "$CFG"; then
    printf '  FAIL  lockdown is present in CONFIG_LSM\n'; bad=$((bad+1))
else
    printf '  OK    lockdown absent from CONFIG_LSM\n'
fi

[ "$bad" -eq 0 ] || die "$bad config expectation(s) not met -- fix the fragments, do not ship this"

cp "$CFG" "$STAGED/config-cybermyth-amd64-final"
cp "$CFG" "$HERE/config-cybermyth-amd64"
note "saved: kernel/config-cybermyth-amd64"

# kernelrelease reads include/config/auto.conf, NOT .config. olddefconfig
# rewrites .config but leaves auto.conf as syncconfig last wrote it, so without
# this the check reads a stale CONFIG_LOCALVERSION and reports the bare version.
make -s -C "$LINUX" LOCALVERSION= syncconfig
REL=$(make -s -C "$LINUX" LOCALVERSION= kernelrelease)
[ "$REL" = "$KREL" ] || die "kernel release is '$REL', expected '$KREL'"
note "kernel release: $REL"

[ "$CONFIG_ONLY" -eq 1 ] && { printf '\nconfig-only: stopping before the build\n'; exit 0; }

# --- Build -------------------------------------------------------------------
# LOCALVERSION= (set but empty) keeps scripts/setlocalversion from appending
# anything of its own. This tree is not a git repo, but its PARENT is, so being
# explicit costs nothing and removes the whole class of "-dirty" surprises.
step "Building (make -j$JOBS bindeb-pkg)"
note "package version: $PKGVERSION"
note "this takes a while -- BTF means full DWARF"

export KBUILD_BUILD_USER=cybermyth
export KBUILD_BUILD_HOST=cybermyth

time make -C "$LINUX" -j"$JOBS" \
    LOCALVERSION= \
    KDEB_PKGVERSION="$PKGVERSION" \
    KDEB_SOURCENAME="$SRCNAME" \
    bindeb-pkg

# bindeb-pkg drops its output in the parent of the kernel tree.
step "Collecting packages"
moved=0
for d in "$BASE"/linux-*"$PKGVERSION"_amd64.deb "$BASE"/linux-libc-dev_*.deb; do
    [ -e "$d" ] || continue
    mv -f "$d" "$PKGDIR/"
    printf '  %s\n' "$(basename "$d")"
    moved=$((moved+1))
done
rm -f "$BASE"/linux-*"$PKGVERSION"_amd64.buildinfo \
      "$BASE"/linux-*"$PKGVERSION"_amd64.changes 2>/dev/null || true
[ "$moved" -gt 0 ] || die "bindeb-pkg produced no .deb in $BASE"

step "Result"
printf '  kernel release : %s\n' "$KREL"
printf '  packages       : %s\n' "$PKGDIR"
ls -la "$PKGDIR"/linux-*.deb 2>/dev/null | sed 's/^/    /'
printf '\n  NOTE: the -dbg and linux-libc-dev packages are built but must NOT go\n'
printf '  on the ISO. mk-rootfs.sh installs only linux-image and linux-headers.\n'
