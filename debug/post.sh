#!/bin/bash
# Read debugging artifacts written by pre.sh's systemd hook, plus any
# u-boot-legacy error.log, and print interesting kernel messages.
#
# Usage: sudo ./post.sh [/dev/sdX]           (default: /dev/sdd)

set -euo pipefail

DEV="${1:-/dev/sdd}"
BOOT_MNT=/mnt/rockboot
STORE_MNT=/mnt/rockstore

if [[ $EUID -ne 0 ]]; then
	echo "Must run as root. Try: sudo $0 $DEV" >&2
	exit 1
fi

if [[ ! -b "$DEV" ]]; then
	echo "Not a block device: $DEV" >&2
	exit 1
fi

cleanup() { umount "$STORE_MNT" 2>/dev/null || true; umount "$BOOT_MNT" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$BOOT_MNT" "$STORE_MNT"
umount "${DEV}1" 2>/dev/null || true
umount "${DEV}2" 2>/dev/null || true

mount "${DEV}1" "$BOOT_MNT"

echo "============================================================"
echo " Boot partition top-level"
echo "============================================================"
ls -la "$BOOT_MNT" | grep -iE 'error\.log|dmesg|lsmod|drm-names|journalctl' || echo "(no debug artefacts)"

if [[ -s "$BOOT_MNT/error.log" ]]; then
	echo
	echo "============================================================"
	echo " u-boot error.log  (writes this = legacy bootloader failed)"
	echo "============================================================"
	cat "$BOOT_MNT/error.log"; echo
fi

if [[ -s "$BOOT_MNT/drm-names.txt" ]]; then
	echo
	echo "============================================================"
	echo " DRM device names (what bound to /dev/dri/*)"
	echo "============================================================"
	cat "$BOOT_MNT/drm-names.txt"
fi

if [[ -s "$BOOT_MNT/lsmod.txt" ]]; then
	echo
	echo "============================================================"
	echo " Loaded panel/DRM/mali modules"
	echo "============================================================"
	grep -iE 'panel|drm|mali|panfrost|rockchip' "$BOOT_MNT/lsmod.txt" || echo "(none matching)"
fi

if [[ -s "$BOOT_MNT/dmesg-boot.txt" ]]; then
	echo
	echo "============================================================"
	echo " dmesg — display / panel / jdi / DSI / VOP relevant lines"
	echo "============================================================"
	grep -iE 'jdi|lt031|panel|\bdsi\b|mipi|dw-mipi|rockchip[-_]drm|\bvop\b|panfrost|mali|drm:|backlight|edid|failed to|probe.*fail|error' \
		"$BOOT_MNT/dmesg-boot.txt" | head -100 || echo "(no matches)"
	echo
	echo "--- full dmesg size ---"
	wc -l "$BOOT_MNT/dmesg-boot.txt"
	echo "(read full text at $BOOT_MNT/dmesg-boot.txt while SD is mounted)"
fi

if [[ -s "$BOOT_MNT/journalctl-boot.txt" ]]; then
	echo
	echo "============================================================"
	echo " journalctl — systemd service failures"
	echo "============================================================"
	grep -iE 'failed|error|panel|sway|weston|emulationstation|drm' \
		"$BOOT_MNT/journalctl-boot.txt" | head -60 || echo "(no matches)"
fi

echo
echo "============================================================"
echo " Partition sizes"
echo "============================================================"
lsblk "$DEV"

umount "$BOOT_MNT"

# Try persistent journal if present
mount "${DEV}2" "$STORE_MNT"
JOURNAL_DIR="$STORE_MNT/.cache/log/journal"
if [[ -d "$JOURNAL_DIR" ]] && compgen -G "$JOURNAL_DIR/*/*.journal" > /dev/null; then
	echo
	echo "============================================================"
	echo " Persistent journal — current boot, errors"
	echo "============================================================"
	journalctl --directory "$JOURNAL_DIR" -b 0 --no-pager -p err 2>/dev/null | head -80 || true
fi
