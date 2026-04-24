#!/bin/bash
# Read debug artefacts written by pre.sh's autostart hook, plus any
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

hr() { printf '%s\n' '============================================================'; }

hr; echo " Boot partition — debug artefacts present?"; hr
ls -la "$BOOT_MNT"/*.txt "$BOOT_MNT/error.log" 2>/dev/null || echo "(none found — autostart hook did not run)"

if [[ -s "$BOOT_MNT/error.log" ]]; then
	echo; hr
	echo " u-boot-legacy error.log (writing this means 1st-stage failed)"
	hr
	cat "$BOOT_MNT/error.log"; echo
fi

if [[ -s "$BOOT_MNT/rppocket-debug.txt" ]]; then
	echo; hr; echo " rppocket-debug.txt (summary from the autostart hook)"; hr
	cat "$BOOT_MNT/rppocket-debug.txt"
fi

if [[ -s "$BOOT_MNT/dmesg-boot.txt" ]]; then
	echo; hr; echo " dmesg — display / panel / DSI / VOP / GPU lines"; hr
	grep -iE 'jdi|lt031|panel|\bdsi\b|mipi|dw-mipi|rockchip[-_]drm|\bvop\b|panfrost|mali|drm:|backlight|edid|failed to|probe.*fail|\berror\b' \
		"$BOOT_MNT/dmesg-boot.txt" | head -120 || echo "(no matches)"
	echo
	echo "--- dmesg full length ---"
	wc -l "$BOOT_MNT/dmesg-boot.txt"
	echo "(full dmesg at $BOOT_MNT/dmesg-boot.txt while SD is mounted — also copied to /tmp below)"
	cp -f "$BOOT_MNT/dmesg-boot.txt" /tmp/rppocket-dmesg.txt 2>/dev/null && \
		echo "copied to /tmp/rppocket-dmesg.txt"
fi

if [[ -s "$BOOT_MNT/journalctl-boot.txt" ]]; then
	echo; hr; echo " journalctl — failures and display-related lines"; hr
	grep -iE 'failed|error|panel|sway|weston|emulationstation|drm|dsi|mipi' \
		"$BOOT_MNT/journalctl-boot.txt" | head -80 || echo "(no matches)"
	cp -f "$BOOT_MNT/journalctl-boot.txt" /tmp/rppocket-journal.txt 2>/dev/null && \
		echo "full journal copied to /tmp/rppocket-journal.txt"
fi

if [[ -s "$BOOT_MNT/lsmod.txt" ]]; then
	echo; hr; echo " lsmod — panel/DRM/mali/rockchip modules"; hr
	grep -iE 'panel|drm|mali|panfrost|rockchip' "$BOOT_MNT/lsmod.txt" || echo "(none matching)"
fi

echo; hr; echo " Partition sizes (sanity)"; hr
lsblk "$DEV"
