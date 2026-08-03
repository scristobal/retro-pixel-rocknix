#!/bin/bash
# Prep a ROCKNIX SD card for a headless RPPocket boot attempt.
#
# By default (without --flash) pre.sh only installs debug hooks on an
# already-flashed card:
#   - persistent systemd-journald config
#   - /storage/.config/autostart/* script that dumps dmesg, journalctl,
#     lsmod, DRM info, SARADC raw values, etc. to the FAT boot partition
#     on every boot.
#
# With --flash, pre.sh also
#   1. gunzips the newest ROCKNIX-*.aarch64-*-a.img.gz from ../target/
#      and dd's it onto the SD first,
#   2. resizes the storage partition so debug hooks and first-boot
#      setup have enough space.
#
# Usage:
#   sudo ./pre.sh                    just (re-)install debug hooks
#   sudo ./pre.sh --flash            flash newest image + hooks
#   sudo ./pre.sh --flash /dev/sdX   pick a non-default SD device
#   sudo ./pre.sh --flash --preserve-wifi /dev/sdX
#                                     securely preserve NetworkManager Wi-Fi
#                                     profiles across the destructive flash
#   sudo ./pre.sh /dev/sdX
#   sudo ./pre.sh --power-slider-test  install a startup handshake for normal
#                                     logind short-action testing
#   sudo ./pre.sh --power-slider-long-test
#                                     verify five-second orderly poweroff and
#                                     preserve its shutdown hook/journal
#   sudo ./pre.sh --power-slider-reliability-test
#                                     remove active diagnostics and passively
#                                     capture ten normal suspend/resume cycles
#   sudo ./pre.sh --release           prepare a production card with no extra
#                                     diagnostics, persistent debug journal,
#                                     experiment markers, or test services
#   sudo ./pre.sh --power-slider-cleanup
#                                     legacy alias for --release
#
# After device testing, insert the SD into the host and tell the agent.
# The agent mounts the SD and reads the full boot/storage logs directly.

set -euo pipefail

FLASH=0
POWER_SLIDER_TEST=0
POWER_SLIDER_LONG_TEST=0
POWER_SLIDER_RELIABILITY_TEST=0
RELEASE=0
PRESERVE_WIFI=0
DEV=/dev/sdb
for arg in "$@"; do
	case "$arg" in
		--flash) FLASH=1 ;;
		--power-slider-test) POWER_SLIDER_TEST=1 ;;
		--power-slider-long-test) POWER_SLIDER_LONG_TEST=1 ;;
		--power-slider-reliability-test) POWER_SLIDER_RELIABILITY_TEST=1 ;;
		--release|--power-slider-cleanup) RELEASE=1 ;;
		--preserve-wifi) PRESERVE_WIFI=1 ;;
		/dev/*)  DEV="$arg" ;;
		*) echo "Unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if (( POWER_SLIDER_TEST + POWER_SLIDER_LONG_TEST + POWER_SLIDER_RELIABILITY_TEST + RELEASE > 1 )); then
	echo "Choose only one power-slider diagnostic/release mode." >&2
	exit 1
fi
if (( PRESERVE_WIFI && ! FLASH )); then
	echo "--preserve-wifi requires --flash." >&2
	exit 1
fi
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

WIFI_BACKUP_DIR=""
WIFI_PROFILE_COUNT=0
cleanup() {
	umount "$STORE_MNT" 2>/dev/null || true
	umount "$BOOT_MNT" 2>/dev/null || true
	if [[ -n "$WIFI_BACKUP_DIR" ]]; then
		rm -rf -- "$WIFI_BACKUP_DIR"
	fi
}
trap cleanup EXIT

mkdir -p "$BOOT_MNT" "$STORE_MNT"
umount "${DEV}1" 2>/dev/null || true
umount "${DEV}2" 2>/dev/null || true

if (( PRESERVE_WIFI )); then
	# Keep credentials off persistent host storage. The root-only tmpfs backup
	# is removed by the EXIT trap on success, failure, or interruption.
	WIFI_BACKUP_DIR=$(mktemp -d /dev/shm/rppocket-wifi.XXXXXX)
	chmod 0700 "$WIFI_BACKUP_DIR"
	echo ">>> Preserving existing Wi-Fi profiles in protected temporary memory..."
	if ! mount -o ro,noload "${DEV}2" "$STORE_MNT"; then
		echo "ERROR: cannot mount the existing STORAGE partition to preserve Wi-Fi." >&2
		exit 1
	fi
	WIFI_SOURCE="$STORE_MNT/.config/NetworkManager/system-connections"
	if [[ -d "$WIFI_SOURCE" ]]; then
		while IFS= read -r -d '' profile; do
			install -m 0600 -- "$profile" "$WIFI_BACKUP_DIR/${profile##*/}"
			((WIFI_PROFILE_COUNT += 1))
		done < <(find "$WIFI_SOURCE" -maxdepth 1 -type f -print0)
	fi
	umount "$STORE_MNT"
	if (( WIFI_PROFILE_COUNT )); then
		echo ">>> Preserved $WIFI_PROFILE_COUNT Wi-Fi profile(s)."
	else
		echo ">>> No existing Wi-Fi profiles were found; continuing with the flash."
	fi
fi

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

if (( WIFI_PROFILE_COUNT )); then
	WIFI_DEST="$STORE_MNT/.config/NetworkManager/system-connections"
	install -d -m 0755 "$WIFI_DEST"
	WIFI_RESTORED=0
	while IFS= read -r -d '' profile; do
		dest="$WIFI_DEST/${profile##*/}"
		install -m 0600 -- "$profile" "$dest"
		cmp -s -- "$profile" "$dest"
		((WIFI_RESTORED += 1))
	done < <(find "$WIFI_BACKUP_DIR" -maxdepth 1 -type f -print0)
	if (( WIFI_RESTORED != WIFI_PROFILE_COUNT )); then
		echo "ERROR: restored $WIFI_RESTORED of $WIFI_PROFILE_COUNT Wi-Fi profiles." >&2
		exit 1
	fi
	echo ">>> Restored $WIFI_RESTORED Wi-Fi profile(s) with mode 0600."
fi

# Persistent journald is the most reliable capture: journald starts in
# sysinit.target, long before graphical.target or any autostart, so even
# if the UI stack never comes up (dead display), the journal still lands
# on disk.  ROCKNIX only bind-mounts persistent /var/log when booted
# with the "debugging" kernel option or when this marker exists (see
# projects/ROCKNIX/packages/sysutils/busybox/system.d/var-log.mount).
# The journald config symlink is installed from /storage/.cache/
# journald.conf.d/ (see projects/ROCKNIX/packages/sysutils/systemd/
# package.mk:274).
mkdir -p "$STORE_MNT/.cache/journald.conf.d" "$STORE_MNT/.cache/log/journal"
touch "$STORE_MNT/.cache/debug.rocknix"
cat > "$STORE_MNT/.cache/journald.conf.d/persist.conf" <<'EOF'
[Journal]
Storage=persistent
ForwardToConsole=yes
SystemMaxUse=64M
EOF

# Let RetroArch pick up the RPPocket built-in gpio-keys device during
# test cycles without requiring a full image rebuild.  The packaged
# copy lives in retroarch-joypads/gamepads/ and will be installed into
# /usr/share/libretro/autoconfig in rebuilt images.
mkdir -p "$STORE_MNT/joypads"
cp "$HERE/../projects/ROCKNIX/packages/emulators/libretro/retroarch/retroarch-joypads/gamepads/gpio-keys.cfg" \
	"$STORE_MNT/joypads/gpio-keys.cfg"

# Install the user's licensed Raspberry Pi PICO-8 build for local test
# images.  ROCKNIX's standalone launcher looks in /storage/roms/pico-8/
# and uses the aarch64 subdirectory when it exists.
PICO8_ZIP="$HERE/pico-8_0.2.7_raspi.zip"
if [[ -f "$PICO8_ZIP" ]]; then
	mkdir -p "$STORE_MNT/games-internal/roms/pico-8/aarch64"
	unzip -q -o "$PICO8_ZIP" 'pico-8/*' -d "$STORE_MNT/games-internal/roms/pico-8/.tmp"
	cp -f "$STORE_MNT/games-internal/roms/pico-8/.tmp/pico-8/"* \
		"$STORE_MNT/games-internal/roms/pico-8/aarch64/"
	rm -rf "$STORE_MNT/games-internal/roms/pico-8/.tmp"
	chmod 0755 "$STORE_MNT/games-internal/roms/pico-8/aarch64"/pico8*
	touch "$STORE_MNT/games-internal/roms/pico-8/Splore.png"
	echo ">>> Installed PICO-8 Raspberry Pi build -> /storage/roms/pico-8/aarch64/"
fi

# Autostart hook — only fires if ROCKNIX's rocknix.target activates
# (which needs graphical.target to settle).  Kept as a nice-to-have
# extra on top of the journal.
mkdir -p "$STORE_MNT/.config/autostart"
rm -f "$STORE_MNT/.config/rppocket-no-dwc2-rebind" \
	"$STORE_MNT/.config/rppocket-stock-init-gpio1"

# 000- prefix so it sorts earliest and runs before anything else user-supplied
cat > "$STORE_MNT/.config/autostart/000-rppocket-debug.sh" <<'EOF'
#!/bin/sh
# Captures kernel & systemd state to the FAT boot partition (/flash) so
# the host can read it by only un-plugging the SD card.  No console
# required.  Runs via ROCKNIX's /usr/bin/autostart.

OUT=/flash

dump_devmem_window() {
	label="$1"
	base="$2"
	words="$3"

	echo "=== devmem ${label} base=${base} words=${words} ==="
	if command -v devmem >/dev/null 2>&1; then
		DEVMEM=devmem
	elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx devmem; then
		DEVMEM="busybox devmem"
	else
		echo "devmem unavailable"
		return
	fi

	i=0
	while [ "$i" -lt "$words" ]; do
		addr=$(printf "0x%08x" $((base + i * 4)))
		printf "%s = " "$addr"
		$DEVMEM "$addr" 32 2>&1 || true
		i=$((i + 1))
	done
}

dump_lowlevel_usb_state() {
	label="$1"

	echo "=== lowlevel usb state: ${label} ==="
	mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

	echo "--- /proc/iomem filtered ---"
	grep -iE 'ff010000|ff140000|ff2c0000|ff300000|usb|phy|grf|pmu' /proc/iomem 2>&1 || true

	echo "--- clk summary filtered ---"
	if [ -f /sys/kernel/debug/clk/clk_summary ]; then
		grep -iE 'usb|otg|phy|480|xin24|hclk|pclk' /sys/kernel/debug/clk/clk_summary 2>&1 || true
	else
		echo "clk_summary unavailable"
	fi

	echo "--- pinmux pins filtered ---"
	for f in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
		[ -f "$f" ] || continue
		echo "--- $f ---"
		grep -iE 'usb|otg|phy|gpio2|gpio3|GPIO2|GPIO3|pin 7[0-9]|pin 11[0-9]|pin 12[0-9]' "$f" 2>&1 || true
	done

	dump_devmem_window "pmu-grf-ff010000" 0xff010000 64
	dump_devmem_window "grf-ff140000" 0xff140000 96
	dump_devmem_window "usb2phy-grf-ff2c0000" 0xff2c0000 96
	dump_devmem_window "dwc2-ff300000-core" 0xff300000 96
	dump_devmem_window "dwc2-ff300000-host" 0xff300400 80
}

dump_broad_register_state() {
	label="$1"

	echo "=== broad register state: ${label} ==="
	# Relevant RK3326/RK817 bring-up blocks for the Wi-Fi rail.
	dump_devmem_window "pmu-grf-ff010000" 0xff010000 256
	dump_devmem_window "gpio0-pmu-ff040000" 0xff040000 64
	dump_devmem_window "grf-ff140000" 0xff140000 512
	dump_devmem_window "gpio1-ff250000" 0xff250000 64
	dump_devmem_window "gpio2-ff260000" 0xff260000 64
	dump_devmem_window "gpio3-ff270000" 0xff270000 64
	dump_devmem_window "usb2phy-grf-ff2c0000" 0xff2c0000 128
	dump_devmem_window "dwc2-ff300000-core" 0xff300000 128
	dump_devmem_window "dwc2-ff300000-host" 0xff300400 96
}

dump_pmic_i2c_state() {
	label="$1"

	echo "=== PMIC / I2C state: ${label} ==="
	mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

	echo "--- i2c adapters ---"
	for d in /sys/class/i2c-adapter/i2c-* ; do
		[ -d "$d" ] || continue
		printf '%s name=%s\n' "$d" "$(cat "$d/name" 2>/dev/null)"
	done

	echo "--- i2c devices ---"
	for d in /sys/bus/i2c/devices/* ; do
		[ -e "$d" ] || continue
		echo "--- $d ---"
		for f in name modalias uevent ; do
			[ -e "$d/$f" ] || continue
			printf '%-14s = %s\n' "$f" "$(tr '\n' ' ' <"$d/$f" 2>/dev/null)"
		done
		[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
	done

	echo "--- debugfs regmap rk8xx/rk817/0-0020 ---"
	for d in /sys/kernel/debug/regmap/* ; do
		[ -d "$d" ] || continue
		case "$d" in
			*rk8*|*rk817*|*0-0020*|*1-0020*|*2-0020*)
				echo "--- $d/name ---"
				cat "$d/name" 2>/dev/null || true
				echo "--- $d/registers ---"
				cat "$d/registers" 2>/dev/null || true
				;;
		esac
	done

	echo "--- i2cdetect ---"
	if command -v i2cdetect >/dev/null 2>&1; then
		for bus in 0 1 2 3 4 5; do
			[ -e "/dev/i2c-$bus" ] || continue
			echo "--- i2c-$bus ---"
			i2cdetect -y "$bus" 2>&1 || true
		done
	else
		echo "i2cdetect unavailable"
	fi

	echo "--- RK817 register dump at 0x20 ---"
	if command -v i2cdump >/dev/null 2>&1; then
		for bus in 0 1 2 3 4 5; do
			[ -e "/dev/i2c-$bus" ] || continue
			if i2cdetect -y "$bus" 0x20 0x20 2>/dev/null | grep -Eq '20|UU'; then
				echo "--- i2cdump -y $bus 0x20 b ---"
				i2cdump -y "$bus" 0x20 b 2>&1 || true
			fi
		done
	else
		echo "i2cdump unavailable"
	fi
}

# /flash is mounted read-only by default on ROCKNIX (see how fs-resize
# handles its log write).  Remount rw, dump, remount ro.
mount -o remount,rw "$OUT" 2>/dev/null

# Preserve any firmware-backed pstore records on the FAT partition before a
# later boot can replace them.
mkdir -p /sys/fs/pstore "$OUT/pstore"
mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true
rm -f "$OUT/pstore/"*
for f in /sys/fs/pstore/* /var/lib/systemd/pstore/*; do
	[ -f "$f" ] || continue
	case "$f" in
		/sys/fs/pstore/*) prefix=kernel ;;
		*) prefix=systemd ;;
	esac
	cp -f "$f" "$OUT/pstore/${prefix}-$(basename "$f")" 2>/dev/null || true
done
{
	echo "=== pstore capture ==="
	date
	mount | grep -E 'pstore|/flash' 2>&1 || true
	for f in /sys/fs/pstore/* /var/lib/systemd/pstore/*; do
		[ -f "$f" ] || continue
		ls -l "$f" 2>&1 || true
	done
	dmesg | grep -iE 'ramoops|pstore' 2>&1 || true
} > "$OUT/pstore-status.txt" 2>&1

# Keep power-slider tests isolated. The broad register/I2C capture is
# intentionally heavy and must not run during a suspend test.
if [ -e /storage/.config/rppocket-power-slider-test.once ] ||
   [ -e /storage/.config/rppocket-power-slider-long-test.once ]; then
	dmesg > "$OUT/dmesg-boot.txt" 2>&1
	journalctl -b -a --no-pager > "$OUT/journalctl-boot.txt" 2>&1
	lsmod > "$OUT/lsmod.txt" 2>&1
	sync
	mount -o remount,ro "$OUT" 2>/dev/null
	exit 0
fi

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

	echo "=== lsmod | wifi/usb networking ==="
	lsmod | grep -iE 'rtl|rtw|cfg80211|mac80211|80211|usbnet|rndis|cdc' 2>&1

	echo "=== USB devices ==="
	for d in /sys/bus/usb/devices/* ; do
		[ -d "$d" ] || continue
		echo "--- $d ---"
		for f in idVendor idProduct manufacturer product serial busnum devnum speed bDeviceClass bDeviceSubClass bDeviceProtocol driver ; do
			[ -e "$d/$f" ] || continue
			printf '%-22s = %s\n' "$f" "$(cat "$d/$f" 2>/dev/null)"
		done
		[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
	done

	echo "=== MMC/SDIO devices ==="
	for d in /sys/bus/mmc/devices/* /sys/class/mmc_host/mmc* ; do
		[ -e "$d" ] || continue
		echo "--- $d ---"
		for f in type name modalias vendor device oemid manfid date fwrev hwrev serial uevent ; do
			[ -e "$d/$f" ] || continue
			printf '%-22s = %s\n' "$f" "$(tr '\n' ' ' <"$d/$f" 2>/dev/null)"
		done
		[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
	done

	echo "=== network interfaces ==="
	for n in /sys/class/net/* ; do
		[ -d "$n" ] || continue
		echo "--- $n ---"
		for f in address operstate carrier type ; do
			[ -e "$n/$f" ] || continue
			printf '%-22s = %s\n' "$f" "$(cat "$n/$f" 2>/dev/null)"
		done
		[ -L "$n/device/driver" ] && echo "driver-link = $(readlink "$n/device/driver" 2>/dev/null)"
	done

	echo "=== rfkill ==="
	rfkill list 2>&1

	echo "=== iw dev ==="
	iw dev 2>&1

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

	dump_lowlevel_usb_state "rocknix-early"
	dump_broad_register_state "rocknix-early"
	dump_pmic_i2c_state "rocknix-early"
} > "$OUT/rppocket-debug.txt" 2>&1

dmesg | grep -iE 'dwc2|usb2phy|usb |usb[0-9]|0bda|8179|rtl|rtw|8188|wifi|wlan|cfg80211|firmware|phy|vcc|regulator' \
	> "$OUT/rppocket-usb-boot.txt" 2>&1

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

		dump_lowlevel_usb_state "rocknix-late"
		dump_broad_register_state "rocknix-late"
		dump_pmic_i2c_state "rocknix-late"

		echo "=== USB / Wi-Fi dmesg lines ==="
		dmesg | grep -iE 'usb|mmc|sdio|rtl|rtw|8188|8189|8723|wifi|wlan|cfg80211|firmware|regulatory' 2>&1 | tail -220

		echo "=== USB devices late ==="
		for d in /sys/bus/usb/devices/* ; do
			[ -d "$d" ] || continue
			echo "--- $d ---"
			for f in idVendor idProduct manufacturer product serial busnum devnum speed bDeviceClass bDeviceSubClass bDeviceProtocol driver ; do
				[ -e "$d/$f" ] || continue
				printf '%-22s = %s\n' "$f" "$(cat "$d/$f" 2>/dev/null)"
			done
			[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
		done

		echo "=== MMC/SDIO devices late ==="
		for d in /sys/bus/mmc/devices/* /sys/class/mmc_host/mmc* ; do
			[ -e "$d" ] || continue
			echo "--- $d ---"
			for f in type name modalias vendor device oemid manfid date fwrev hwrev serial uevent ; do
				[ -e "$d/$f" ] || continue
				printf '%-22s = %s\n' "$f" "$(tr '\n' ' ' <"$d/$f" 2>/dev/null)"
			done
			[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
		done

		echo "=== network interfaces late ==="
		for n in /sys/class/net/* ; do
			[ -d "$n" ] || continue
			echo "--- $n ---"
			for f in address operstate carrier type ; do
				[ -e "$n/$f" ] || continue
				printf '%-22s = %s\n' "$f" "$(cat "$n/$f" 2>/dev/null)"
			done
			[ -L "$n/device/driver" ] && echo "driver-link = $(readlink "$n/device/driver" 2>/dev/null)"
		done

		echo "=== iw dev late ==="
		iw dev 2>&1

		echo "=== GPIO (looking for panel reset, backlight en) ==="
		cat /sys/kernel/debug/gpio 2>/dev/null | head -80

	} > "$OUT/rppocket-late.txt" 2>&1

	dmesg                       > "$OUT/dmesg-late.txt"      2>&1
	journalctl -b -a --no-pager > "$OUT/journalctl-late.txt" 2>&1
	dmesg | grep -iE 'dwc2|usb2phy|usb |usb[0-9]|0bda|8179|rtl|rtw|8188|wifi|wlan|cfg80211|firmware|phy|vcc|regulator' \
		> "$OUT/rppocket-usb-late.txt" 2>&1

	sync
	mount -o remount,ro "$OUT" 2>/dev/null
) &

mount -o remount,ro "$OUT" 2>/dev/null
EOF
chmod +x "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"

# Remove harnesses produced by obsolete versions of this helper even when the
# current invocation is preparing another diagnostic mode.
rm -f "$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh" \
	"$STORE_MNT/.config"/rppocket-pm-* \
	"$STORE_MNT/.config/system.d"/rppocket-pm-* \
	"$STORE_MNT/.config/system.d/multi-user.target.wants"/rppocket-pm-* \
	"$STORE_MNT/.config/system.d/rocknix.target.wants"/rppocket-pm-*

# Optional startup gate for the normal logind power-slider policy.
if (( POWER_SLIDER_TEST )); then
mkdir -p "$STORE_MNT/.config/system.d/rocknix.target.wants" \
	"$STORE_MNT/.config/system.d/multi-user.target.wants"
cat > "$STORE_MNT/.config/rppocket-power-slider-test.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-power-slider-test.once
LOG=/storage/.cache/log/rppocket-power-slider-test.log
LED_GPIO=17
QUIRK_BASE='/usr/lib/autostart/quirks/devices/FunnyPlaying RetroPixel Pocket'

[ -e "$MARK" ] || exit 0
rm -f "$MARK"
mkdir -p /storage/.cache/log
: >"$LOG"
exec >>"$LOG" 2>&1

echo "=== RPPocket normal systemd power-slider test ==="
date
uname -a

if [ ! -e /dev/mali0 ] || [ ! -d /sys/module/mali_kbase ] || \
   [ ! -d /sys/bus/platform/devices/ff400000.gpu ]; then
	echo "ERROR: GPU was expected but is not fully present"
	sync
	exit 1
fi
if [ ! -L /sys/bus/platform/devices/rockchip-suspend/driver ]; then
	echo "ERROR: rockchip-suspend policy driver is not bound"
	sync
	exit 1
fi
if [ ! -x "$QUIRK_BASE/sleep.d/pre/001-power-key-inhibit" ] || \
   [ ! -x "$QUIRK_BASE/sleep.d/post/001-power-key-inhibit" ]; then
	echo "ERROR: RPPocket wake-event inhibitor quirks are not installed"
	sync
	exit 1
fi
if ! grep -qx 'HandlePowerKey=suspend' \
	/run/systemd/logind.conf.d/50-rppocket-power-key.conf 2>/dev/null || \
   ! grep -qx 'HandlePowerKeyLongPress=poweroff' \
	/run/systemd/logind.conf.d/50-rppocket-power-key.conf 2>/dev/null; then
	echo "ERROR: RPPocket logind policy drop-in is not installed"
	sync
	exit 1
fi

short_action="$(busctl get-property org.freedesktop.login1 \
	/org/freedesktop/login1 org.freedesktop.login1.Manager \
	HandlePowerKey 2>&1)"
long_action="$(busctl get-property org.freedesktop.login1 \
	/org/freedesktop/login1 org.freedesktop.login1.Manager \
	HandlePowerKeyLongPress 2>&1)"
echo "HandlePowerKey: $short_action"
echo "HandlePowerKeyLongPress: $long_action"
case "$short_action" in
	*'"suspend"'*) ;;
	*) echo "ERROR: effective short action is not suspend"; sync; exit 1 ;;
esac
case "$long_action" in
	*'"poweroff"'*) ;;
	*) echo "ERROR: effective long action is not poweroff"; sync; exit 1 ;;
esac

echo "confirmed: production power-key policy and wake inhibitor are active"
for f in /sys/power/state /sys/power/mem_sleep; do
	printf '%s: ' "$f"
	cat "$f" 2>&1 || true
done
sync

if [ ! -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo "$LED_GPIO" > /sys/class/gpio/export 2>/dev/null || true
	sleep 1
fi
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo out > "/sys/class/gpio/gpio${LED_GPIO}/direction" 2>/dev/null || true
	for ignored in 1 2 3 4 5; do
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
	done
	echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
fi

echo "READY: normal systemd power-key handling is active"
sync
exit 0
EOF
chmod +x "$STORE_MNT/.config/rppocket-power-slider-test.sh"
cat > "$STORE_MNT/.config/system.d/rppocket-power-slider-test.service" <<'EOF'
[Unit]
Description=Verify normal RPPocket systemd power-slider policy
After=local-fs.target systemd-logind.service rocknix-autostart.service

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/storage/.config/rppocket-power-slider-test.sh

[Install]
WantedBy=rocknix.target
EOF
rm -f "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-test.service"
ln -sf ../rppocket-power-slider-test.service \
	"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service"
rm -f "$STORE_MNT/.cache/log/rppocket-power-slider-test.log"
touch "$STORE_MNT/.config/rppocket-power-slider-test.once"
else
	rm -f "$STORE_MNT/.config/rppocket-power-slider-test.sh" \
		"$STORE_MNT/.config/rppocket-power-slider-test.once" \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-test.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-test.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service"
fi

if (( POWER_SLIDER_LONG_TEST )); then
mkdir -p "$STORE_MNT/.config/system.d/rocknix.target.wants" \
	"$STORE_MNT/.config/system.d/multi-user.target.wants"
cat > "$STORE_MNT/.config/rppocket-power-slider-long-test.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-power-slider-long-test.once
LOG=/storage/.cache/log/rppocket-power-slider-long-test.log
PROOF=/storage/.cache/log/rppocket-power-slider-long-orderly-shutdown.log
PREVIOUS=/storage/.cache/log/rppocket-power-slider-short-v1-journal.log
CURRENT=/storage/.cache/log/rppocket-power-slider-long-v1-journal.log
LED_GPIO=17
QUIRK_BASE='/usr/lib/autostart/quirks/devices/FunnyPlaying RetroPixel Pocket'

case "$1" in
start)
	rm -f "$MARK"
	mkdir -p /storage/.cache/log
	: >"$LOG"
	rm -f "$PROOF" "$CURRENT"
	exec >>"$LOG" 2>&1

	echo "=== RPPocket five-second long-press test ==="
	date
	uname -a
	journalctl -b -1 --no-pager -o short-monotonic >"$PREVIOUS" 2>&1 || true

	if [ ! -e /dev/mali0 ] || [ ! -d /sys/module/mali_kbase ] || \
	   [ ! -d /sys/bus/platform/devices/ff400000.gpu ]; then
		echo "ERROR: GPU was expected but is not fully present"
		sync
		exit 1
	fi
	if [ ! -L /sys/bus/platform/devices/rockchip-suspend/driver ]; then
		echo "ERROR: rockchip-suspend policy driver is not bound"
		sync
		exit 1
	fi
	if [ ! -x "$QUIRK_BASE/sleep.d/pre/001-power-key-inhibit" ] || \
	   [ ! -x "$QUIRK_BASE/sleep.d/post/001-power-key-inhibit" ]; then
		echo "ERROR: RPPocket wake-event inhibitor quirks are not installed"
		sync
		exit 1
	fi
	if ! grep -qx 'HandlePowerKey=suspend' \
		/run/systemd/logind.conf.d/50-rppocket-power-key.conf 2>/dev/null || \
	   ! grep -qx 'HandlePowerKeyLongPress=poweroff' \
		/run/systemd/logind.conf.d/50-rppocket-power-key.conf 2>/dev/null; then
		echo "ERROR: RPPocket logind policy drop-in is not installed"
		sync
		exit 1
	fi

	short_action="$(busctl get-property org.freedesktop.login1 \
		/org/freedesktop/login1 org.freedesktop.login1.Manager \
		HandlePowerKey 2>&1)"
	long_action="$(busctl get-property org.freedesktop.login1 \
		/org/freedesktop/login1 org.freedesktop.login1.Manager \
		HandlePowerKeyLongPress 2>&1)"
	echo "HandlePowerKey: $short_action"
	echo "HandlePowerKeyLongPress: $long_action"
	case "$short_action" in
		*'"suspend"'*) ;;
		*) echo "ERROR: effective short action is not suspend"; sync; exit 1 ;;
	esac
	case "$long_action" in
		*'"poweroff"'*) ;;
		*) echo "ERROR: effective long action is not poweroff"; sync; exit 1 ;;
	esac

	echo "confirmed: production five-second long-press policy is active"
	sync

	if [ ! -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
		echo "$LED_GPIO" > /sys/class/gpio/export 2>/dev/null || true
		sleep 1
	fi
	if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
		echo out > "/sys/class/gpio/gpio${LED_GPIO}/direction" 2>/dev/null || true
		for ignored in 1 2 3 4 5; do
			echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
			sleep 0.15
			echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
			sleep 0.15
		done
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
	fi

	echo "READY: hold continuously for native systemd long-press poweroff"
	sync
	;;
stop)
	{
		echo "ORDERLY SHUTDOWN HOOK REACHED"
		date
		printf 'uptime: '
		cat /proc/uptime
		echo "The active long-test service was stopped by the systemd shutdown transaction."
	} >"$PROOF"
	timeout 15 journalctl -b --no-pager -o short-monotonic >"$CURRENT" 2>&1 || true
	sync
	;;
*)
	echo "usage: $0 start|stop" >&2
	exit 2
	;;
esac
EOF
chmod +x "$STORE_MNT/.config/rppocket-power-slider-long-test.sh"
cat > "$STORE_MNT/.config/system.d/rppocket-power-slider-long-test.service" <<'EOF'
[Unit]
Description=Verify RPPocket five-second orderly poweroff
ConditionPathExists=/storage/.config/rppocket-power-slider-long-test.once
RequiresMountsFor=/storage
After=systemd-logind.service rocknix-autostart.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
TimeoutStopSec=30
ExecStart=/storage/.config/rppocket-power-slider-long-test.sh start
ExecStop=/storage/.config/rppocket-power-slider-long-test.sh stop

[Install]
WantedBy=rocknix.target
EOF
rm -f "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-long-test.service"
ln -sf ../rppocket-power-slider-long-test.service \
	"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-long-test.service"
rm -f "$STORE_MNT/.cache/log/rppocket-power-slider-long-test.log" \
	"$STORE_MNT/.cache/log/rppocket-power-slider-long-orderly-shutdown.log" \
	"$STORE_MNT/.cache/log/rppocket-power-slider-long-v1-journal.log"
touch "$STORE_MNT/.config/rppocket-power-slider-long-test.once"
else
	rm -f "$STORE_MNT/.config/rppocket-power-slider-long-test.sh" \
		"$STORE_MNT/.config/rppocket-power-slider-long-test.once" \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-long-test.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-long-test.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-long-test.service"
fi

if (( POWER_SLIDER_RELIABILITY_TEST )); then
mkdir -p "$STORE_MNT/.config/system.d/rocknix.target.wants" \
	"$STORE_MNT/.config/system.d/multi-user.target.wants"
cat > "$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-power-slider-reliability-test.once
LOG=/storage/.cache/log/rppocket-power-slider-reliability-test.log
PROOF=/storage/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log
JOURNAL=/storage/.cache/log/rppocket-power-slider-reliability-v1-journal.log
QUIRK_BASE='/usr/lib/autostart/quirks/devices/FunnyPlaying RetroPixel Pocket'

case "$1" in
start)
	rm -f "$MARK"
	mkdir -p /storage/.cache/log
	: >"$LOG"
	rm -f "$PROOF" "$JOURNAL"
	exec >>"$LOG" 2>&1

	echo "=== RPPocket ten-cycle production reliability test ==="
	date
	uname -a

	if [ -e /storage/.config/autostart/000-rppocket-debug.sh ]; then
		echo "ERROR: broad debug hook is still installed"
		sync
		exit 1
	fi
	if [ ! -e /dev/mali0 ] || [ ! -d /sys/module/mali_kbase ] || \
	   [ ! -d /sys/bus/platform/devices/ff400000.gpu ]; then
		echo "ERROR: GPU was expected but is not fully present"
		sync
		exit 1
	fi
	if [ ! -L /sys/bus/platform/devices/rockchip-suspend/driver ]; then
		echo "ERROR: rockchip-suspend policy driver is not bound"
		sync
		exit 1
	fi
	if [ ! -x "$QUIRK_BASE/sleep.d/pre/001-power-key-inhibit" ] || \
	   [ ! -x "$QUIRK_BASE/sleep.d/post/001-power-key-inhibit" ]; then
		echo "ERROR: RPPocket wake-event inhibitor quirks are not installed"
		sync
		exit 1
	fi
	if ! grep -qx 'HandlePowerKey=suspend' \
		/run/systemd/logind.conf.d/50-rppocket-power-key.conf 2>/dev/null || \
	   ! grep -qx 'HandlePowerKeyLongPress=poweroff' \
		/run/systemd/logind.conf.d/50-rppocket-power-key.conf 2>/dev/null; then
		echo "ERROR: RPPocket logind policy drop-in is not installed"
		sync
		exit 1
	fi

	short_action="$(busctl get-property org.freedesktop.login1 \
		/org/freedesktop/login1 org.freedesktop.login1.Manager \
		HandlePowerKey 2>&1)"
	long_action="$(busctl get-property org.freedesktop.login1 \
		/org/freedesktop/login1 org.freedesktop.login1.Manager \
		HandlePowerKeyLongPress 2>&1)"
	echo "HandlePowerKey: $short_action"
	echo "HandlePowerKeyLongPress: $long_action"
	case "$short_action" in
		*'"suspend"'*) ;;
		*) echo "ERROR: effective short action is not suspend"; sync; exit 1 ;;
	esac
	case "$long_action" in
		*'"poweroff"'*) ;;
		*) echo "ERROR: effective long action is not poweroff"; sync; exit 1 ;;
	esac

	echo "confirmed: passive collector active; no suspend initiator or broad debug hook"
	echo "READY: perform ten normal short suspend/resume cycles"
	sync
	;;
stop)
	{
		echo "RELIABILITY ORDERLY SHUTDOWN HOOK REACHED"
		date
		printf 'uptime: '
		cat /proc/uptime
		echo "The passive reliability collector was stopped by the shutdown transaction."
	} >"$PROOF"
	timeout 20 journalctl -b --no-pager -o short-monotonic >"$JOURNAL" 2>&1 || true
	sync
	;;
*)
	echo "usage: $0 start|stop" >&2
	exit 2
	;;
esac
EOF
chmod +x "$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh"
cat > "$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service" <<'EOF'
[Unit]
Description=Passively capture RPPocket suspend/resume reliability
ConditionPathExists=/storage/.config/rppocket-power-slider-reliability-test.once
RequiresMountsFor=/storage
After=systemd-logind.service rocknix-autostart.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
TimeoutStopSec=35
ExecStart=/storage/.config/rppocket-power-slider-reliability-test.sh start
ExecStop=/storage/.config/rppocket-power-slider-reliability-test.sh stop

[Install]
WantedBy=rocknix.target
EOF
rm -f "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service"
ln -sf ../rppocket-power-slider-reliability-test.service \
	"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service"
rm -f "$STORE_MNT/.config/autostart/000-rppocket-debug.sh" \
	"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-test.log" \
	"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log" \
	"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-v1-journal.log"
touch "$STORE_MNT/.config/rppocket-power-slider-reliability-test.once"
else
	rm -f "$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh" \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.once" \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service"
fi

if (( RELEASE )); then
	rm -f "$STORE_MNT/.config/autostart/000-rppocket-debug.sh" \
		"$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh" \
		"$STORE_MNT/.config/rppocket-no-dwc2-rebind" \
		"$STORE_MNT/.config/rppocket-stock-init-gpio1" \
		"$STORE_MNT/.config"/rppocket-pm-* \
		"$STORE_MNT/.config/system.d"/rppocket-pm-* \
		"$STORE_MNT/.config/system.d/multi-user.target.wants"/rppocket-pm-* \
		"$STORE_MNT/.config/system.d/rocknix.target.wants"/rppocket-pm-* \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh" \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.once" \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.cache/debug.rocknix" \
		"$STORE_MNT/.cache/journald.conf.d/persist.conf" \
		"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-test.log" \
		"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log" \
		"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-v1-journal.log"
	rm -f "$STORE_MNT/.cache/log"/rppocket-*.log
	rm -rf "$STORE_MNT/.cache/log/journal"
	rmdir "$STORE_MNT/.cache/journald.conf.d" 2>/dev/null || true
fi

rm -f "$STORE_MNT/.config/autostart/010-rppocket-wifi-rail-scan.sh" \
	"$STORE_MNT/.config/autostart/011-rppocket-rk817-gpio-scan.sh" \
	"$STORE_MNT/.config/autostart/012-rppocket-amux-gpio-scan.sh"

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

# Do not report a prepared power-slider test unless every storage-backed
# component is present and internally consistent. The user keeps the card in the host after
# this step so the agent can independently inspect these files before boot.
rm -f "$STORE_MNT/.config/rppocket-test-install.manifest" \
	"$STORE_MNT/.config/rppocket-pm-test-install.manifest"
if (( POWER_SLIDER_TEST )); then
	test -x "$STORE_MNT/.config/rppocket-power-slider-test.sh"
	test -f "$STORE_MNT/.config/rppocket-power-slider-test.once"
	test -f "$STORE_MNT/.config/system.d/rppocket-power-slider-test.service"
	test -L "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service"
	test "$(readlink "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service")" = \
		"../rppocket-power-slider-test.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-test.service"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-test.log"
	grep -q 'effective short action is not suspend' \
		"$STORE_MNT/.config/rppocket-power-slider-test.sh"
	grep -q 'effective long action is not poweroff' \
		"$STORE_MNT/.config/rppocket-power-slider-test.sh"
	grep -q 'RPPocket wake-event inhibitor quirks are not installed' \
		"$STORE_MNT/.config/rppocket-power-slider-test.sh"
	grep -q 'READY: normal systemd power-key handling is active' \
		"$STORE_MNT/.config/rppocket-power-slider-test.sh"
	grep -q '/storage/.config/rppocket-power-slider-test.once' \
		"$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
	{
		echo "harness=rppocket-production-power-slider-v1"
		sha256sum \
			"$STORE_MNT/.config/rppocket-power-slider-test.sh" \
			"$STORE_MNT/.config/system.d/rppocket-power-slider-test.service" \
			"$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
		echo "service_target=rocknix.target"
		echo "service_link=../rppocket-power-slider-test.service"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-test-install.manifest"
	echo ">>> VERIFIED: normal power-slider policy gate, marker, and link are installed."
elif (( POWER_SLIDER_LONG_TEST )); then
	test -x "$STORE_MNT/.config/rppocket-power-slider-long-test.sh"
	test -f "$STORE_MNT/.config/rppocket-power-slider-long-test.once"
	test -f "$STORE_MNT/.config/system.d/rppocket-power-slider-long-test.service"
	test -L "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-long-test.service"
	test "$(readlink "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-long-test.service")" = \
		"../rppocket-power-slider-long-test.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-long-test.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-long-test.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-long-orderly-shutdown.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-long-v1-journal.log"
	grep -q 'ConditionPathExists=/storage/.config/rppocket-power-slider-long-test.once' \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-long-test.service"
	grep -q 'HandlePowerKeyLongPress' "$STORE_MNT/.config/rppocket-power-slider-long-test.sh"
	grep -q 'ORDERLY SHUTDOWN HOOK REACHED' "$STORE_MNT/.config/rppocket-power-slider-long-test.sh"
	grep -q 'journalctl -b -1' "$STORE_MNT/.config/rppocket-power-slider-long-test.sh"
	grep -q '/storage/.config/rppocket-power-slider-long-test.once' \
		"$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
	{
		echo "harness=rppocket-production-power-slider-long-v1"
		sha256sum \
			"$STORE_MNT/.config/rppocket-power-slider-long-test.sh" \
			"$STORE_MNT/.config/system.d/rppocket-power-slider-long-test.service" \
			"$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
		echo "service_target=rocknix.target"
		echo "service_link=../rppocket-power-slider-long-test.service"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-test-install.manifest"
	echo ">>> VERIFIED: long-press gate, shutdown proof hook, marker, and link are installed."
elif (( POWER_SLIDER_RELIABILITY_TEST )); then
	test -x "$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh"
	test -f "$STORE_MNT/.config/rppocket-power-slider-reliability-test.once"
	test -f "$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service"
	test -L "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service"
	test "$(readlink "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service")" = \
		"../rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-long-test.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service"
	test ! -e "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-test.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-v1-journal.log"
	grep -q 'ConditionPathExists=/storage/.config/rppocket-power-slider-reliability-test.once' \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service"
	grep -q 'RemainAfterExit=yes' \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service"
	grep -q 'RELIABILITY ORDERLY SHUTDOWN HOOK REACHED' \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh"
	grep -q 'no suspend initiator or broad debug hook' \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh"
	{
		echo "harness=rppocket-production-power-slider-reliability-v1"
		sha256sum \
			"$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh" \
			"$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service"
		echo "broad_debug_hook=absent"
		echo "service_target=rocknix.target"
		echo "service_link=../rppocket-power-slider-reliability-test.service"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-test-install.manifest"
	echo ">>> VERIFIED: passive reliability collector is sole service; broad debug is absent."
elif (( RELEASE )); then
	test ! -e "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
	test ! -e "$STORE_MNT/.config/rppocket-no-dwc2-rebind"
	test ! -e "$STORE_MNT/.config/rppocket-stock-init-gpio1"
	test ! -e "$STORE_MNT/.config/rppocket-test-install.manifest"
	test ! -e "$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh"
	test ! -e "$STORE_MNT/.config/rppocket-power-slider-reliability-test.once"
	test ! -e "$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.cache/debug.rocknix"
	test ! -e "$STORE_MNT/.cache/journald.conf.d/persist.conf"
	test ! -e "$STORE_MNT/.cache/log/journal"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-test.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-v1-journal.log"
	if find "$STORE_MNT/.config" -maxdepth 3 \
		-name 'rppocket-pm-*' -print -quit | grep -q .; then
		echo "ERROR: an obsolete RPPocket PM harness file remains" >&2
		exit 1
	fi
	if find "$STORE_MNT/.cache/log" -maxdepth 1 -type f \
		-name 'rppocket-*.log' -print -quit | grep -q .; then
		echo "ERROR: an RPPocket diagnostic log remains" >&2
		exit 1
	fi
	if [[ -d "$STORE_MNT/.config/system.d" ]] &&
		find "$STORE_MNT/.config/system.d" -maxdepth 2 -type l \
			-name 'rppocket-*' -print -quit | grep -q .; then
		echo "ERROR: an RPPocket test service link remains" >&2
		exit 1
	fi
	echo ">>> VERIFIED: release card has no extra diagnostics or test services."
fi
sync

umount "$STORE_MNT"

# --- boot partition: wipe stale debug artefacts from a prior run -----------
mount "${DEV}1" "$BOOT_MNT"
rm -f \
	"$BOOT_MNT/dmesg-boot.txt" \
	"$BOOT_MNT/lsmod.txt" \
	"$BOOT_MNT/journalctl-boot.txt" \
	"$BOOT_MNT/rppocket-debug.txt" \
	"$BOOT_MNT/rppocket-late.txt" \
	"$BOOT_MNT/rppocket-usb-boot.txt" \
	"$BOOT_MNT/rppocket-usb-late.txt" \
	"$BOOT_MNT/rppocket-rocker-plan.txt" \
	"$BOOT_MNT/pstore-status.txt" \
	"$BOOT_MNT/dmesg-late.txt" \
	"$BOOT_MNT/journalctl-late.txt" \
	"$BOOT_MNT"/event*.log \
	"$BOOT_MNT"/event*.hex \
	"$BOOT_MNT/error.log"
rm -rf "$BOOT_MNT/pstore"
sync
umount "$BOOT_MNT"

if (( POWER_SLIDER_TEST || POWER_SLIDER_LONG_TEST || POWER_SLIDER_RELIABILITY_TEST )); then
	echo ">>> PREPARED, NOT CLEARED TO BOOT: leave the card in this PC."
	echo ">>> Tell the agent 'prepared' so the image and harness can be verified read-only."
elif (( RELEASE )); then
	echo ">>> Release preparation complete. The card is ready for normal use."
else
	echo ">>> OK. Insert SD into RPPocket and power on."
fi
if (( POWER_SLIDER_TEST )); then
	echo ">>> Five rapid blue flashes within 90 sec prove production policy is active."
	echo ">>> Then perform only the separately requested short-action test."
elif (( POWER_SLIDER_LONG_TEST )); then
	echo ">>> Five rapid blue flashes within 90 sec prove long-press policy is active."
	echo ">>> Then hold continuously and release as soon as shutdown visibly begins."
elif (( POWER_SLIDER_RELIABILITY_TEST )); then
	echo ">>> Wait 90 sec for normal startup, then perform ten requested short cycles."
	echo ">>> Only the passive shutdown journal collector remains active."
elif (( RELEASE )); then
	:
else
	echo ">>> Wait ~3 min (or until the blinking LED stops changing cadence),"
	echo ">>> power off with a long press, pull the SD, and tell the agent it is inserted."
fi
echo
if (( FLASH )); then
	echo "    (Flashed from $(basename "$IMG"))"
fi
