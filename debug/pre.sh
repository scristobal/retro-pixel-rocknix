#!/bin/bash
# Install debugging hooks onto the ROCKNIX SD card before boot.
#
# ROCKNIX runs scripts under /storage/.config/autostart/* after its own
# platform/device quirks and after graphical.target, but BEFORE
# EmulationStation starts.  This is a reliable headless diagnostic hook:
# it fires even when the display pipeline is completely dead, because it
# doesn't need a working compositor.
#
# Usage: sudo ./pre.sh [/dev/sdX]          (default: /dev/sdd)

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

SIZE_GB=$(lsblk -bno SIZE "$DEV" | head -1 | awk '{printf "%.0f", $1/1073741824}')
if [[ "$SIZE_GB" -gt 64 ]]; then
	echo "Refusing to touch $DEV — it is ${SIZE_GB} GB, too large for the RPPocket SD card." >&2
	exit 1
fi

echo ">>> Target: $DEV (${SIZE_GB} GB).  Press Ctrl-C within 3s to abort."
sleep 3

cleanup() { umount "$STORE_MNT" 2>/dev/null || true; umount "$BOOT_MNT" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$BOOT_MNT" "$STORE_MNT"
umount "${DEV}1" 2>/dev/null || true
umount "${DEV}2" 2>/dev/null || true

# --- storage partition: drop hooks ------------------------------------------
mount "${DEV}2" "$STORE_MNT"

# Persistent journald is the most reliable capture: journald starts in
# sysinit.target, long before graphical.target or any autostart, so even
# if the UI stack never comes up (dead display), the journal still lands
# on disk.  ROCKNIX maps /storage/.cache/journald.conf.d/ to
# /usr/lib/systemd/journald.conf.d/ (see projects/ROCKNIX/packages/
# sysutils/systemd/package.mk:274).
mkdir -p "$STORE_MNT/.cache/journald.conf.d"
cat > "$STORE_MNT/.cache/journald.conf.d/persist.conf" <<'EOF'
[Journal]
Storage=persistent
ForwardToConsole=yes
SystemMaxUse=64M
EOF

# Autostart hook — only fires if ROCKNIX's rocknix.target activates
# (which needs graphical.target to settle).  Kept as a nice-to-have
# extra on top of the journal.
mkdir -p "$STORE_MNT/.config/autostart"

# 000- prefix so it sorts earliest and runs before anything else user-supplied
cat > "$STORE_MNT/.config/autostart/000-rppocket-debug.sh" <<'EOF'
#!/bin/sh
# Captures kernel & systemd state to the FAT boot partition (/flash) so
# the host can read it by only un-plugging the SD card.  No console
# required.  Runs via ROCKNIX's /usr/bin/autostart.

OUT=/flash

# /flash is mounted read-only by default on ROCKNIX (see how fs-resize
# handles its log write).  Remount rw, dump, remount ro.
mount -o remount,rw "$OUT" 2>/dev/null

{
	echo "=== date ==="
	date

	echo "=== uname -a ==="
	uname -a

	echo "=== /proc/device-tree/model ==="
	cat /proc/device-tree/model 2>/dev/null; echo

	echo "=== /proc/device-tree/compatible ==="
	tr -d '\000' </proc/device-tree/compatible 2>/dev/null; echo

	echo "=== lsblk ==="
	lsblk 2>&1

	echo "=== DRM devices ==="
	for f in /sys/class/drm/*/name /sys/kernel/debug/dri/*/name ; do
		[ -f "$f" ] || continue
		echo "--- $f ---"
		cat "$f" 2>/dev/null
	done

	echo "=== lsmod | panel/drm/mali ==="
	lsmod | grep -iE 'panel|drm|mali|panfrost|rockchip' 2>&1

	echo "=== systemd failed units ==="
	systemctl --no-pager --failed 2>&1

	echo "=== SARADC raw channel values ==="
	# On RK3326 the hardware-ID is on saradc channel 0.  We want the
	# raw number so we can teach u-boot-legacy's cmd/hwrev.c about this
	# device and remove the DTB-rename SD hack.
	for f in /sys/bus/iio/devices/iio:device*/in_voltage*_raw ; do
		[ -f "$f" ] || continue
		echo "--- $f ---"
		cat "$f" 2>/dev/null
	done
	echo "=== SARADC device metadata ==="
	for f in /sys/bus/iio/devices/iio:device*/name ; do
		[ -f "$f" ] || continue
		echo "--- $f ---"
		cat "$f" 2>/dev/null
	done
} > "$OUT/rppocket-debug.txt" 2>&1

dmesg                       > "$OUT/dmesg-boot.txt"      2>&1
journalctl -b -a --no-pager > "$OUT/journalctl-boot.txt" 2>&1
lsmod                       > "$OUT/lsmod.txt"           2>&1

sync
mount -o remount,ro "$OUT" 2>/dev/null
EOF
chmod +x "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"

umount "$STORE_MNT"

# --- boot partition: wipe stale debug artefacts from a prior run -----------
mount "${DEV}1" "$BOOT_MNT"
rm -f \
	"$BOOT_MNT/dmesg-boot.txt" \
	"$BOOT_MNT/lsmod.txt" \
	"$BOOT_MNT/journalctl-boot.txt" \
	"$BOOT_MNT/rppocket-debug.txt" \
	"$BOOT_MNT/error.log"
sync
umount "$BOOT_MNT"

echo ">>> OK. Insert SD into RPPocket and power on."
echo ">>> Wait ~3 min (or until the blinking LED stops changing cadence),"
echo ">>> power off with a long press, pull the SD, then run post.sh."
