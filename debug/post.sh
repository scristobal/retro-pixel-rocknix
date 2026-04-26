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
	echo; hr; echo " rppocket-debug.txt (EARLY snapshot — before sway start)"; hr
	cat "$BOOT_MNT/rppocket-debug.txt"
fi

if [[ -s "$BOOT_MNT/rppocket-late.txt" ]]; then
	echo; hr; echo " rppocket-late.txt (LATE snapshot — 45s into boot)"; hr
	cat "$BOOT_MNT/rppocket-late.txt"
fi

if [[ -s "$BOOT_MNT/dmesg-late.txt" ]]; then
	echo; hr
	echo " LATE dmesg — panel prepare/enable attempts"
	hr
	grep -iE 'jdi|lt031|panel.*(prepare|enable|unprepare|disable)|dsi.*attach|dsi.*host|mipi.*write|drm.*connector|drm.*mode|drm:|modeset|sway|weston' \
		"$BOOT_MNT/dmesg-late.txt" | head -80 || echo "(no matches)"
	cp -f "$BOOT_MNT/dmesg-late.txt" /tmp/rppocket-dmesg-late.txt 2>/dev/null
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

# --- input-event capture ----------------------------------------------------
if compgen -G "$BOOT_MNT/event*.log" > /dev/null 2>&1 || \
   compgen -G "$BOOT_MNT/event*.hex" > /dev/null 2>&1; then
	echo; hr; echo " evtest captures (60s window during boot)"; hr
	for f in "$BOOT_MNT"/event*.log "$BOOT_MNT"/event*.hex; do
		[ -f "$f" ] || continue
		echo "--- $(basename "$f") ---"
		# evtest log: keep only EV_KEY value=1 (press) lines, plus
		# the device-name header so we know which event* device this is.
		if [[ "$f" == *.log ]]; then
			grep -E '^Input device name:|EV_KEY.*value 1' "$f" | head -40
		else
			head -20 "$f"
		fi
		echo
	done
	for f in "$BOOT_MNT"/event*.log "$BOOT_MNT"/event*.hex; do
		[ -f "$f" ] || continue
		cp -f "$f" "/tmp/rppocket-$(basename "$f")" 2>/dev/null
	done
	echo "(full evtest logs copied to /tmp/rppocket-event*.log)"
fi

echo; hr; echo " Partition sizes (sanity)"; hr
lsblk "$DEV"

# --- persistent journal on the storage partition ----------------------------
echo
umount "$BOOT_MNT" 2>/dev/null || true
if mount "${DEV}2" "$STORE_MNT" 2>/dev/null; then
	JDIR=""
	for cand in "$STORE_MNT/var/log/journal" "$STORE_MNT/.cache/log/journal"; do
		if compgen -G "$cand/*/*.journal" > /dev/null 2>&1; then
			JDIR="$cand"; break
		fi
	done
	if [[ -n "$JDIR" ]]; then
		hr; echo " Persistent journal: $JDIR"; hr
		echo "(copying to /tmp/rppocket-journal-full.txt for easier paging)"
		journalctl --directory "$JDIR" -b 0 --no-pager > /tmp/rppocket-journal-full.txt 2>&1 || true
		echo
		echo "--- current boot: panel/DSI/DRM/mali/sway/weston/errors ---"
		journalctl --directory "$JDIR" -b 0 --no-pager 2>/dev/null | \
			grep -iE 'jdi|lt031|panel|dsi|mipi|dw-mipi|rockchip[-_]drm|\bvop\b|panfrost|mali|drm:|backlight|sway|weston|failed|error' | \
			head -120 || true
		echo
		echo "--- boots recorded ---"
		journalctl --directory "$JDIR" --list-boots --no-pager 2>&1 | head -10
	else
		hr; echo " No persistent journal found on storage."; hr
		echo "If you ran pre.sh from the updated debug scripts, journald"
		echo "config is at /storage/.cache/journald.conf.d/persist.conf —"
		echo "the journal only starts persisting from the NEXT boot."
	fi
	umount "$STORE_MNT" 2>/dev/null || true
fi
