#!/bin/bash
# Prep a ROCKNIX SD card for a headless RPPocket boot attempt.
#
# By default (--no-flash) pre.sh only installs debug hooks on an
# already-flashed card:
#   - persistent systemd-journald config
#   - /storage/.config/autostart/* script that dumps dmesg, journalctl,
#     lsmod, DRM info, SARADC raw values, etc. to the FAT boot partition
#     on every boot.
#
# With --flash, pre.sh also
#   1. gunzips the newest ROCKNIX-*.aarch64-*-a.img.gz from ../target/
#      and dd's it onto the SD first,
#   2. renames extlinux.conf.rppocket -> extlinux.conf so u-boot selects
#      our DTB instead of falling through to the OGA default.
#
# Usage:
#   sudo ./pre.sh                    just (re-)install debug hooks
#   sudo ./pre.sh --flash            flash newest image + rename + hooks
#   sudo ./pre.sh --flash /dev/sdX   pick a non-default SD device
#   sudo ./pre.sh /dev/sdX

set -euo pipefail

FLASH=0
DEV=/dev/sdd
for arg in "$@"; do
	case "$arg" in
		--flash) FLASH=1 ;;
		/dev/*)  DEV="$arg" ;;
		*) echo "Unknown arg: $arg" >&2; exit 1 ;;
	esac
done

BOOT_MNT=/mnt/rockboot
STORE_MNT=/mnt/rockstore
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HERE/../target"

if [[ $EUID -ne 0 ]]; then
	echo "Must run as root. Try: sudo $0 $*" >&2
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

if (( FLASH )); then
	IMG=$(ls -t "$TARGET_DIR"/ROCKNIX-*.aarch64-*-a.img.gz 2>/dev/null | head -1 || true)
	if [[ -z "$IMG" ]]; then
		echo "No flashable image found under $TARGET_DIR" >&2
		exit 1
	fi
	echo ">>> Target: $DEV (${SIZE_GB} GB)"
	echo ">>> Flash:  $IMG"
	echo ">>> This will WIPE the SD card.  Ctrl-C within 5s to abort."
	sleep 5
else
	echo ">>> Target: $DEV (${SIZE_GB} GB).  Press Ctrl-C within 3s to abort."
	sleep 3
fi

cleanup() { umount "$STORE_MNT" 2>/dev/null || true; umount "$BOOT_MNT" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$BOOT_MNT" "$STORE_MNT"
umount "${DEV}1" 2>/dev/null || true
umount "${DEV}2" 2>/dev/null || true

if (( FLASH )); then
	echo ">>> Writing image (this takes 1-2 min)..."
	gunzip -c "$IMG" | dd of="$DEV" bs=4M status=progress conv=fsync
	sync
	# Let the kernel re-read the partition table
	partprobe "$DEV" 2>/dev/null || true
	sleep 1

	# If extlinux.conf.rppocket exists (older builds without the ADC
	# patches), overlay it onto extlinux.conf.  Newer builds select the
	# rppocket DTB via u-boot's ADC-based auto-detection, so no
	# standalone .rppocket variant is generated and this step is a no-op.
	mount "${DEV}1" "$BOOT_MNT"
	if [[ -f "$BOOT_MNT/extlinux/extlinux.conf.rppocket" ]]; then
		echo ">>> Overlaying extlinux.conf.rppocket onto extlinux.conf..."
		cp "$BOOT_MNT/extlinux/extlinux.conf.rppocket" "$BOOT_MNT/extlinux/extlinux.conf"
	else
		echo ">>> No extlinux.conf.rppocket variant — relying on u-boot ADC auto-detection."
	fi
	umount "$BOOT_MNT"

	# Pre-grow the storage partition to fill the SD card.  Otherwise
	# the debug-hook files we drop under /storage/.config/ and
	# /storage/.cache/ trick on-device fs-resize into thinking the
	# system is already initialised (see projects/.../busybox/scripts/
	# fs-resize, the /storage/.config || /storage/.cache check), so it
	# refuses to resize.  The 32 MB placeholder partition then
	# overflows during first-boot userland setup with "No space left on
	# device" errors everywhere.  Do the resize ourselves, up front.
	echo ">>> Resizing storage partition to fill the SD..."
	parted -s "$DEV" resizepart 2 100%
	partprobe "$DEV" 2>/dev/null || true
	sleep 1
	e2fsck -f -p "${DEV}2" || true
	resize2fs "${DEV}2"
fi

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
echo
if (( FLASH )); then
	echo "    (Flashed from $(basename "$IMG"))"
fi
