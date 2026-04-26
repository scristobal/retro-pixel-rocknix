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

	echo "=== ALSA cards ==="
	cat /proc/asound/cards 2>&1
	echo "--- aplay -l ---"
	aplay -l 2>&1 | head -20
	echo "--- amixer -c0 contents ---"
	amixer -c0 contents 2>&1 | head -80

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

	# ---- input/pinctrl diagnostics --------------------------------------
	# All three of these together let us localise *why* a button doesn't
	# register: pinmux-pins shows whether our btn_pins pinctrl applied;
	# /sys/kernel/debug/gpio shows the live level for every line (a pin
	# pulled-up but never driven low = switch not wired); /proc/bus/input/
	# devices + /proc/interrupts confirm gpio-keys claimed the IRQs we
	# expect.

	echo "=== /sys/kernel/debug/pinctrl/*/pinmux-pins (gpio2/gpio3 only) ==="
	for f in /sys/kernel/debug/pinctrl/*/pinmux-pins ; do
		[ -f "$f" ] || continue
		echo "--- $f ---"
		grep -E 'pin [0-9]+ \(GPIO[23]_[AB]' "$f" 2>/dev/null
	done

	echo "=== /sys/kernel/debug/gpio (all banks) ==="
	cat /sys/kernel/debug/gpio 2>/dev/null

	echo "=== /proc/bus/input/devices ==="
	cat /proc/bus/input/devices 2>&1

	echo "=== /proc/interrupts | gpio-keys ==="
	grep -E 'gpio_keys|CPU' /proc/interrupts 2>&1
} > "$OUT/rppocket-debug.txt" 2>&1

# 120-second input-event capture — runs in background while the user
# presses each physical button once, slowly, in the documented order.
# Writes to /storage/.cache (always rw); when capture finishes, this
# block does its own remount-rw of /flash and copies the logs out.
mkdir -p /storage/.cache/evtest
rm -f /storage/.cache/evtest/* 2>/dev/null
(
	for ev in /dev/input/event*; do
		[ -e "$ev" ] || continue
		name=$(basename "$ev")
		# evtest may not exist; fall back to a hex dump of the raw
		# struct input_event (24 bytes on aarch64: 16-byte timeval +
		# u16 type + u16 code + s32 value).  Either output is enough
		# to identify which GPIO is firing.
		if command -v evtest >/dev/null 2>&1; then
			( timeout 120 evtest --grab "$ev" \
				> "/storage/.cache/evtest/$name.log" 2>&1 ) &
		else
			( timeout 120 od -An -tx1 -w24 "$ev" \
				> "/storage/.cache/evtest/$name.hex" 2>&1 ) &
		fi
	done
	wait
	# Copy out of /storage onto /flash so post.sh can pull them.
	mount -o remount,rw "$OUT" 2>/dev/null
	cp -f /storage/.cache/evtest/* "$OUT/" 2>/dev/null
	sync
	mount -o remount,ro "$OUT" 2>/dev/null
) &

dmesg                       > "$OUT/dmesg-boot.txt"      2>&1
journalctl -b -a --no-pager > "$OUT/journalctl-boot.txt" 2>&1
lsmod                       > "$OUT/lsmod.txt"           2>&1

sync

# Early capture done.  Now schedule a DELAYED second capture so we see
# what happens AFTER ROCKNIX's autostart tries to start the UI service
# (sway on RK3326).  The early capture fires before sway is invoked;
# by the time the delayed one fires, sway has had its chance to open
# /dev/dri/card0 and drive the panel (or fail trying).
(
	sleep 45
	mount -o remount,rw "$OUT" 2>/dev/null

	{
		echo "=== LATE capture: date ==="
		date

		echo "=== /sys/class/drm (connectors, any attached?) ==="
		for d in /sys/class/drm/card*-*; do
			[ -d "$d" ] || continue
			echo "--- $d ---"
			echo "status: $(cat "$d/status" 2>/dev/null)"
			echo "enabled: $(cat "$d/enabled" 2>/dev/null)"
			echo "modes:"
			cat "$d/modes" 2>/dev/null
		done

		echo "=== /sys/class/drm/card0/device listing ==="
		ls -la /sys/class/drm/ 2>&1

		echo "=== systemctl status sway ==="
		systemctl status sway.service --no-pager 2>&1

		echo "=== systemctl status weston ==="
		systemctl status weston.service --no-pager 2>&1

		echo "=== systemctl status emustation ==="
		systemctl status emustation.service --no-pager 2>&1

		echo "=== failed units (late) ==="
		systemctl --no-pager --failed 2>&1

		echo "=== ps (who has /dev/dri open) ==="
		ps -ef 2>&1

		echo "=== lsof /dev/dri/card0 (if lsof exists) ==="
		lsof /dev/dri/card0 2>&1 | head -30

		echo "=== sway log ==="
		cat /var/log/sway.log 2>/dev/null | tail -100

		echo "=== backlight ==="
		for b in /sys/class/backlight/* ; do
			[ -d "$b" ] || continue
			echo "--- $b ---"
			for f in brightness max_brightness bl_power actual_brightness type ; do
				printf '%-20s = %s\n' "$f" "$(cat "$b/$f" 2>/dev/null)"
			done
		done

		echo "=== force-toggling backlight to max (experiment) ==="
		for b in /sys/class/backlight/* ; do
			[ -d "$b" ] || continue
			MAX=$(cat "$b/max_brightness" 2>/dev/null)
			echo 0 > "$b/bl_power" 2>/dev/null
			echo "$MAX" > "$b/brightness" 2>/dev/null
			echo "poked $b -> brightness=$MAX bl_power=0"
		done
		sleep 3

		echo "=== backlight after toggle ==="
		for b in /sys/class/backlight/* ; do
			[ -d "$b" ] || continue
			echo "--- $b ---"
			for f in brightness max_brightness bl_power actual_brightness ; do
				printf '%-20s = %s\n' "$f" "$(cat "$b/$f" 2>/dev/null)"
			done
		done

		echo "=== PWM channels (what's running) ==="
		for p in /sys/class/pwm/pwmchip*/pwm*/ ; do
			[ -d "$p" ] || continue
			echo "--- $p ---"
			for f in enable period duty_cycle polarity ; do
				printf '%-14s = %s\n' "$f" "$(cat "$p/$f" 2>/dev/null)"
			done
		done

		echo "=== regulator summary ==="
		cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -80

		echo "=== GPIO (looking for panel reset, backlight en) ==="
		cat /sys/kernel/debug/gpio 2>/dev/null | head -80

		# Experiment: swap sway's black background for white, then tell
		# sway to reload config.  If the panel is actually being driven
		# correctly, we should see the screen turn white (not black).
		echo "=== swapping sway config to white background ==="
		if [ -f /storage/.config/sway/config ]; then
			sed -i 's/#000000/#ffffff/g' /storage/.config/sway/config 2>&1
			grep "bg " /storage/.config/sway/config 2>&1
			# Find sway's control socket and send reload
			SWAYSOCK=$(find /var/run -name 'sway-ipc.*.sock' 2>/dev/null | head -1)
			echo "SWAYSOCK=$SWAYSOCK"
			if [ -n "$SWAYSOCK" ]; then
				SWAYSOCK="$SWAYSOCK" sway -t reload 2>&1 || true
			fi
			# Fallback: SIGHUP sway
			pkill -HUP -x sway 2>&1
		fi

		echo "=== backlight blink test (500ms off, 500ms on, 500ms off, 500ms on) ==="
		# A visible-on-dark-screen indicator that the backlight *can* be
		# modulated: if you watch the device during this test, you should
		# see a faint 0.5Hz cycle.  If nothing at all changes, backlight
		# isn't actually emitting light even at brightness=255.
		for b in /sys/class/backlight/* ; do
			[ -d "$b" ] || continue
			MAX=$(cat "$b/max_brightness" 2>/dev/null)
			for i in 1 2; do
				echo 0 > "$b/brightness" 2>/dev/null
				sleep 0.5
				echo "$MAX" > "$b/brightness" 2>/dev/null
				sleep 0.5
			done
		done
	} > "$OUT/rppocket-late.txt" 2>&1

	dmesg                       > "$OUT/dmesg-late.txt"      2>&1
	journalctl -b -a --no-pager > "$OUT/journalctl-late.txt" 2>&1

	sync
	mount -o remount,ro "$OUT" 2>/dev/null
) &

mount -o remount,ro "$OUT" 2>/dev/null
EOF
chmod +x "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"

# --- copy any local ROMs from debug/ to /storage/games-internal/roms/ ------
# Drop a ROM next to pre.sh and it gets installed at flash time.  ROCKNIX's
# automount script bind-mounts /storage/games-internal/roms over /storage/roms
# at boot (see projects/.../rocknix/sources/scripts/automount), so files
# written directly into /storage/roms get masked.  The on-disk location we
# want is games-internal/roms/<system>/.
declare -A ROM_DESTS=(
	[gb]=gb [gbc]=gbc [gba]=gba
	[nes]=nes [smc]=snes [sfc]=snes
	[md]=megadrive [gen]=megadrive [smd]=megadrive
	[n64]=n64 [z64]=n64 [v64]=n64
	[pce]=pcengine
)
shopt -s nullglob
for src in "$HERE"/*.{gb,gbc,gba,nes,smc,sfc,md,gen,smd,n64,z64,v64,pce}; do
	ext="${src##*.}"
	dest="${ROM_DESTS[$ext]}"
	[ -n "$dest" ] || continue
	mkdir -p "$STORE_MNT/games-internal/roms/$dest"
	cp -f "$src" "$STORE_MNT/games-internal/roms/$dest/"
	echo ">>> Copied $(basename "$src") -> /storage/games-internal/roms/$dest/"
done
shopt -u nullglob

umount "$STORE_MNT"

# --- boot partition: wipe stale debug artefacts from a prior run -----------
mount "${DEV}1" "$BOOT_MNT"
rm -f \
	"$BOOT_MNT/dmesg-boot.txt" \
	"$BOOT_MNT/lsmod.txt" \
	"$BOOT_MNT/journalctl-boot.txt" \
	"$BOOT_MNT/rppocket-debug.txt" \
	"$BOOT_MNT/rppocket-late.txt" \
	"$BOOT_MNT/dmesg-late.txt" \
	"$BOOT_MNT/journalctl-late.txt" \
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
