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
#   2. resizes the storage partition so debug hooks and first-boot
#      setup have enough space.
#
# Usage:
#   sudo ./pre.sh                    just (re-)install debug hooks
#   sudo ./pre.sh --flash            flash newest image + hooks
#   sudo ./pre.sh --flash /dev/sdX   pick a non-default SD device
#   sudo ./pre.sh /dev/sdX
#   sudo ./pre.sh --no-dwc2-rebind   install hooks but skip the late DWC2
#                                     unbind/rebind experiment
#   sudo ./pre.sh --amux-gpio-scan    install a GPIO3 PB0/PB3/PB5 scan hook
#   sudo ./pre.sh --stock-init-gpio1  reproduce stock init's GPIO1 high /
#                                     GPIO114 low state before logging
#   sudo ./pre.sh --pm-test-devices   install a one-shot suspend device-phase
#                                     test; may be combined with --flash
#   sudo ./pre.sh --pm-test-devices-no-gpu
#                                     run the test from systemd for an image
#                                     whose GPU node is disabled
#   sudo ./pre.sh --pm-freeze-no-gpu   enter real freeze on a GPU-disabled image
#   sudo ./pre.sh --pm-freeze          enter real freeze with the GPU restored
#                                     and wait for one power-slider wake action
#   sudo ./pre.sh --pm-deep            enter deep suspend-to-RAM with the stock
#                                     BL31 policy and wait for one slider wake
#   sudo ./pre.sh --power-slider-test  install a startup handshake for normal
#                                     logind short-action testing
#   sudo ./pre.sh --power-slider-long-test
#                                     verify five-second orderly poweroff and
#                                     preserve its shutdown hook/journal
#   sudo ./pre.sh --power-slider-reliability-test
#                                     remove active diagnostics and passively
#                                     capture ten normal suspend/resume cycles
#   sudo ./pre.sh --power-slider-cleanup
#                                     remove the passive collector after the
#                                     validated production reliability run
#
# After device testing, insert the SD into the host and tell the agent.
# The agent mounts the SD and reads the full boot/storage logs directly.

set -euo pipefail

FLASH=0
DWC2_REBIND=1
WIFI_RAIL_SCAN=0
RK817_GPIO_SCAN=0
AMUX_GPIO_SCAN=0
STOCK_INIT_GPIO1=0
PM_TEST_DEVICES=0
PM_TEST_DEVICES_NO_GPU=0
PM_FREEZE_NO_GPU=0
PM_FREEZE=0
PM_DEEP=0
POWER_SLIDER_TEST=0
POWER_SLIDER_LONG_TEST=0
POWER_SLIDER_RELIABILITY_TEST=0
POWER_SLIDER_CLEANUP=0
DEV=/dev/sdb
for arg in "$@"; do
	case "$arg" in
		--flash) FLASH=1 ;;
		--no-dwc2-rebind) DWC2_REBIND=0 ;;
		--wifi-rail-scan) WIFI_RAIL_SCAN=1 ;;
		--rk817-gpio-scan) RK817_GPIO_SCAN=1 ;;
		--amux-gpio-scan) AMUX_GPIO_SCAN=1 ;;
		--stock-init-gpio1) STOCK_INIT_GPIO1=1 ;;
		--pm-test-devices) PM_TEST_DEVICES=1 ;;
		--pm-test-devices-no-gpu) PM_TEST_DEVICES_NO_GPU=1 ;;
		--pm-freeze-no-gpu) PM_FREEZE_NO_GPU=1 ;;
		--pm-freeze) PM_FREEZE=1 ;;
		--pm-deep) PM_DEEP=1 ;;
		--power-slider-test) POWER_SLIDER_TEST=1 ;;
		--power-slider-long-test) POWER_SLIDER_LONG_TEST=1 ;;
		--power-slider-reliability-test) POWER_SLIDER_RELIABILITY_TEST=1 ;;
		--power-slider-cleanup) POWER_SLIDER_CLEANUP=1 ;;
		/dev/*)  DEV="$arg" ;;
		*) echo "Unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if (( PM_TEST_DEVICES + PM_TEST_DEVICES_NO_GPU + PM_FREEZE_NO_GPU + PM_FREEZE + PM_DEEP + POWER_SLIDER_TEST + POWER_SLIDER_LONG_TEST + POWER_SLIDER_RELIABILITY_TEST + POWER_SLIDER_CLEANUP > 1 )); then
	echo "Choose only one PM diagnostic mode." >&2
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
if (( DWC2_REBIND )); then
	rm -f "$STORE_MNT/.config/rppocket-no-dwc2-rebind"
else
	touch "$STORE_MNT/.config/rppocket-no-dwc2-rebind"
fi
if (( STOCK_INIT_GPIO1 )); then
	touch "$STORE_MNT/.config/rppocket-stock-init-gpio1"
else
	rm -f "$STORE_MNT/.config/rppocket-stock-init-gpio1"
fi

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

	echo "--- RK817 candidate dumps at 0x20 ---"
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

apply_stock_init_gpio1() {
	echo "=== stock init GPIO1 experiment ==="
	if [ ! -e /storage/.config/rppocket-stock-init-gpio1 ]; then
		echo "disabled"
		return
	fi

	# Stock busybox init exports GPIO1 (GPIO0_PA1) and drives it high.
	# The broad stock-vs-ROCKNIX diff shows this as a remaining early
	# GPIO0 delta while the YJ33 Wi-Fi rail is powered on stock.
	for gpio in 1 114; do
		if [ ! -d "/sys/class/gpio/gpio${gpio}" ]; then
			echo "$gpio" > /sys/class/gpio/export 2>/dev/null || true
			sleep 0.1
		fi
		echo 0 > "/sys/class/gpio/gpio${gpio}/active_low" 2>/dev/null || true
	done

	echo out > /sys/class/gpio/gpio1/direction 2>/dev/null || true
	echo 1 > /sys/class/gpio/gpio1/value 2>/dev/null || true
	echo out > /sys/class/gpio/gpio114/direction 2>/dev/null || true
	echo 0 > /sys/class/gpio/gpio114/value 2>/dev/null || true

	printf 'gpio1  direction=%s value=%s\n' \
		"$(cat /sys/class/gpio/gpio1/direction 2>/dev/null || echo '?')" \
		"$(cat /sys/class/gpio/gpio1/value 2>/dev/null || echo '?')"
	printf 'gpio114 direction=%s value=%s\n' \
		"$(cat /sys/class/gpio/gpio114/direction 2>/dev/null || echo '?')" \
		"$(cat /sys/class/gpio/gpio114/value 2>/dev/null || echo '?')"
}

# /flash is mounted read-only by default on ROCKNIX (see how fs-resize
# handles its log write).  Remount rw, dump, remount ro.
mount -o remount,rw "$OUT" 2>/dev/null

# A DPM watchdog panic is written to the temporary RPPocket ramoops region.
# Preserve it on the FAT partition at the start of the next boot, before any
# later experiment can replace the persistent ring contents.
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

# Keep one-shot PM tests isolated. The broad register/I2C capture is
# intentionally heavy and can perturb the I2C controller while PM diagnostics
# are running. Deep and production-policy modes have no GPU-expectation mode
# file, so recognize their fresh markers explicitly; rocknix-autostart
# completes before either service runs.
if [ -e /storage/.config/rppocket-pm-test-devices-mode ] ||
   [ -e /storage/.config/rppocket-pm-test-devices-no-gpu-mode ] ||
   [ -e /storage/.config/rppocket-pm-deep.once ] ||
   [ -e /storage/.config/rppocket-power-slider-test.once ] ||
   [ -e /storage/.config/rppocket-power-slider-long-test.once ]; then
	dmesg > "$OUT/dmesg-boot.txt" 2>&1
	journalctl -b -a --no-pager > "$OUT/journalctl-boot.txt" 2>&1
	lsmod > "$OUT/lsmod.txt" 2>&1
	sync
	mount -o remount,ro "$OUT" 2>/dev/null
	exit 0
fi

{
	apply_stock_init_gpio1

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

dmesg | grep -iE 'RPPDBG|dwc2|usb2phy|usb |usb[0-9]|0bda|8179|rtl|rtw|8188|wifi|wlan|cfg80211|firmware|phy|vcc|regulator' \
	> "$OUT/rppocket-usb-boot.txt" 2>&1

# NOTE: the boot-time evtest --grab capture has been removed.  evtest --grab
# calls EVIOCGRAB which exclusively claims the input device, so for the
# duration of the capture window EmulationStation can't read any button —
# every key looks dead until the timer expires.  We already extracted the
# rocker GPIO map from earlier captures; leaving the grab in place was
# blocking real-use testing.

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

			dump_lowlevel_usb_state "rocknix-late-before-rebind"
			dump_broad_register_state "rocknix-late-before-rebind"
			dump_pmic_i2c_state "rocknix-late-before-rebind"

		echo "=== delayed DWC2 rebind experiment ==="
		echo "time before optional rebind: $(date)"
		echo "--- USB devices before DWC2 rebind ---"
		for d in /sys/bus/usb/devices/* ; do
			[ -d "$d" ] || continue
			echo "--- $d ---"
			for f in idVendor idProduct manufacturer product serial busnum devnum speed bDeviceClass bDeviceSubClass bDeviceProtocol driver ; do
				[ -e "$d/$f" ] || continue
				printf '%-22s = %s\n' "$f" "$(cat "$d/$f" 2>/dev/null)"
			done
			[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
		done
		if [ -e /storage/.config/rppocket-no-dwc2-rebind ]; then
			echo "DWC2 rebind skipped by /storage/.config/rppocket-no-dwc2-rebind"
		elif [ -e /sys/bus/platform/drivers/dwc2/ff300000.usb ]; then
			echo "--- no runtime USB2PHY writes before rebind ---"
			echo "unbind ff300000.usb"
			echo ff300000.usb > /sys/bus/platform/drivers/dwc2/unbind 2>&1 || true
			sleep 3
			echo "bind ff300000.usb"
			echo ff300000.usb > /sys/bus/platform/drivers/dwc2/bind 2>&1 || true
			sleep 8
		else
			echo "dwc2 platform device ff300000.usb is not currently bound"
			ls -la /sys/bus/platform/drivers/dwc2 2>&1 || true
		fi
		echo "time after optional rebind: $(date)"
		echo "--- USB devices after DWC2 rebind ---"
		for d in /sys/bus/usb/devices/* ; do
			[ -d "$d" ] || continue
			echo "--- $d ---"
			for f in idVendor idProduct manufacturer product serial busnum devnum speed bDeviceClass bDeviceSubClass bDeviceProtocol driver ; do
				[ -e "$d/$f" ] || continue
				printf '%-22s = %s\n' "$f" "$(cat "$d/$f" 2>/dev/null)"
			done
			[ -L "$d/driver" ] && echo "driver-link = $(readlink "$d/driver" 2>/dev/null)"
		done
		echo "--- network after DWC2 rebind ---"
		for n in /sys/class/net/* ; do
			[ -d "$n" ] || continue
			echo "--- $n ---"
			for f in address operstate carrier type ; do
				[ -e "$n/$f" ] || continue
				printf '%-22s = %s\n' "$f" "$(cat "$n/$f" 2>/dev/null)"
			done
			[ -L "$n/device/driver" ] && echo "driver-link = $(readlink "$n/device/driver" 2>/dev/null)"
		done
		echo "--- iw dev after DWC2 rebind ---"
		iw dev 2>&1
		echo "--- lsmod wifi/usb after DWC2 rebind ---"
		lsmod | grep -iE 'rtl|rtw|8188|cfg80211|mac80211|80211|usb' 2>&1
		echo "--- RPPDBG dmesg lines after DWC2 rebind ---"
		dmesg | grep -i 'RPPDBG' 2>&1 | tail -260
		echo "--- dmesg tail after DWC2 rebind ---"
		dmesg | grep -iE 'RPPDBG|usb|rtl|rtw|8188|wifi|wlan|cfg80211|firmware|phy|vcc|regulator' 2>&1 | tail -260

			dump_lowlevel_usb_state "rocknix-late-after-rebind"
			dump_broad_register_state "rocknix-late-after-rebind"

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
	dmesg | grep -iE 'RPPDBG|dwc2|usb2phy|usb |usb[0-9]|0bda|8179|rtl|rtw|8188|wifi|wlan|cfg80211|firmware|phy|vcc|regulator' \
		> "$OUT/rppocket-usb-late.txt" 2>&1

	sync
	mount -o remount,ro "$OUT" 2>/dev/null
) &

mount -o remount,ro "$OUT" 2>/dev/null
EOF
chmod +x "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"

# Optional one-shot kernel suspend-stage diagnostic.  At the "devices"
# pm_test level Linux suspends drivers, waits five seconds, and reverses the
# operation without entering the CPU/platform sleep state.  It therefore does
# not depend on the power key, RTC, or any other hardware wake source.
if (( PM_TEST_DEVICES )); then
cat > "$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-pm-test-devices.once
LOG=/storage/.cache/log/rppocket-pm-test-devices.log

[ -e "$MARK" ] || exit 0
rm -f "$MARK"

(
	sleep 45

	dump_power_state() {
		label="$1"
		echo "=== $label ==="
		date
		for f in /sys/power/state /sys/power/mem_sleep /sys/power/pm_test \
			 /sys/power/pm_async /sys/power/pm_print_times \
			 /sys/power/pm_debug_messages /sys/power/pm_wakeup_irq \
			 /sys/power/wakeup_count; do
			[ -e "$f" ] || continue
			echo "--- $f ---"
			cat "$f" 2>&1 || true
		done

		mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
		echo "--- /sys/kernel/debug/suspend_stats ---"
		for f in /sys/kernel/debug/suspend_stats/*; do
			[ -f "$f" ] || continue
			printf '%s = ' "${f##*/}"
			cat "$f" 2>&1 || true
		done
		echo "--- /sys/kernel/debug/wakeup_sources ---"
		cat /sys/kernel/debug/wakeup_sources 2>&1 || true

		echo "--- PMIC child power/wakeup state ---"
		for d in /sys/devices/platform/ff180000.i2c/i2c-0/0-0020 \
			 /sys/devices/platform/ff180000.i2c/i2c-0/0-0020/rk805-pwrkey.* \
			 /sys/devices/platform/ff180000.i2c/i2c-0/0-0020/rk808-rtc.*; do
			[ -d "$d" ] || continue
			printf '%s: ' "$d"
			cat "$d/power/wakeup" 2>&1 || true
		done

		echo "--- /proc/interrupts ---"
		cat /proc/interrupts 2>&1 || true
		echo "--- dmesg tail ---"
		dmesg 2>&1 | tail -300
	}

	mkdir -p /storage/.cache/log
	: >"$LOG"
	exec >>"$LOG" 2>&1
	echo "=== RPPocket one-shot pm_test=devices diagnostic ==="
	dump_power_state before

	# Stock 4.4 builds DWC2 as a module and explicitly removes it in the
	# pre-sleep hook. ROCKNIX previously built it in, making its modules.bad
	# entry ineffective. Reproduce and verify the stock precondition before
	# entering the kernel directly.
	echo "=== stock-matching DWC2 unload ==="
	echo "--- before ---"
	lsmod | grep -E '^dwc2([[:space:]]|$)' || echo "dwc2 not listed"
	if [ -d /sys/module/dwc2 ]; then
		modprobe -r dwc2
		unload_status=$?
		echo "modprobe -r dwc2 status: $unload_status"
	else
		echo "dwc2 was not loaded"
	fi
	echo "--- after ---"
	lsmod | grep -E '^dwc2([[:space:]]|$)' || echo "dwc2 not listed"
	if [ -d /sys/module/dwc2 ]; then
		echo "ERROR: dwc2 remains loaded; refusing to run an invalid stock-matching test"
		sync
		exit 1
	fi
	echo "confirmed: /sys/module/dwc2 is absent"

	# Emit every callback start/completion to the ramoops console ring.  If a
	# callback blocks, CONFIG_DPM_WATCHDOG will panic after 20 seconds and name
	# the device; the normal one-second panic reboot then preserves the record.
	[ ! -w /sys/power/pm_print_times ] || echo 1 > /sys/power/pm_print_times
	[ ! -w /sys/power/pm_debug_messages ] || echo 1 > /sys/power/pm_debug_messages
	echo devices > /sys/power/pm_test
	echo "=== armed pm_test ==="
	cat /sys/power/pm_test
	logger -t rppocket-pm-test \
		"Writing freeze directly with pm_test=devices; automatic return expected in five seconds"
	sync

	# Do not use systemctl here: its suspend request returns to the caller
	# before systemd enters the kernel, which races with resetting pm_test.
	# The direct sysfs write blocks until the kernel has reversed the tested
	# device-suspend phase.
	echo "=== writing freeze to /sys/power/state ==="
	date
	echo freeze > /sys/power/state
	status=$?

	echo "=== /sys/power/state returned: $status ==="
	dump_power_state after
	echo none > /sys/power/pm_test 2>/dev/null || true
	modprobe dwc2
	echo "modprobe dwc2 restore status: $?"
	sync
) &

exit 0
EOF
chmod +x "$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh"
touch "$STORE_MNT/.config/rppocket-pm-test-devices.once" \
	"$STORE_MNT/.config/rppocket-pm-test-devices-mode"
else
	rm -f "$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh" \
		"$STORE_MNT/.config/rppocket-pm-test-devices.once" \
		"$STORE_MNT/.config/rppocket-pm-test-devices-mode"
fi

# Run headless GPU-isolation and real-freeze diagnostics from multi-user.target
# rather than depending on graphical autostart. Each mode records and validates
# whether the GPU is expected to be absent or present.
if (( PM_TEST_DEVICES_NO_GPU )); then
mkdir -p "$STORE_MNT/.config/system.d/multi-user.target.wants"
cat > "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-pm-test-devices-no-gpu.once
LOG=/storage/.cache/log/rppocket-pm-callback-walk.log

[ -e "$MARK" ] || exit 0
rm -f "$MARK"

# The stock RPPocket DTS identifies GPIO0_C1 (global GPIO 17) as the
# active-high blue status LED. Keep it solid while this headless test is
# running so powered-off and device-stage-hung outcomes remain distinguishable.
LED_GPIO=17
if [ ! -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo "$LED_GPIO" > /sys/class/gpio/export 2>/dev/null || true
	sleep 1
fi
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo out > "/sys/class/gpio/gpio${LED_GPIO}/direction" 2>/dev/null || true
	# An unmistakable startup handshake: if this five-flash sequence is not
	# seen, the user must stop rather than interpreting a black screen.
	for ignored in 1 2 3 4 5; do
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
	done
	echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
fi

sleep 45

mkdir -p /storage/.cache/log
: >"$LOG"
exec >>"$LOG" 2>&1

echo "=== RPPocket bounded PM callback walk after RK817 sequence fix ==="
date
uname -a

echo "--- verify GPU isolation ---"
if [ -e /dev/mali0 ] || [ -d /sys/module/mali_kbase ]; then
	echo "ERROR: Mali is present; refusing an invalid no-GPU test"
	ls -l /dev/mali* 2>&1 || true
	lsmod | grep -i mali 2>&1 || true
	sync
	exit 1
fi
echo "confirmed: no /dev/mali0 and no mali_kbase module"
if [ -d /sys/bus/platform/devices/ff400000.gpu ]; then
	echo "ERROR: ff400000.gpu platform device exists despite disabled DT status"
	sync
	exit 1
fi
echo "confirmed: no ff400000.gpu platform device"

echo "--- stock-matching DWC2 unload ---"
lsmod | grep -E '^dwc2([[:space:]]|$)' || echo "dwc2 not listed"
if [ -d /sys/module/dwc2 ]; then
	modprobe -r dwc2
	echo "modprobe -r dwc2 status: $?"
fi
if [ -d /sys/module/dwc2 ]; then
	echo "ERROR: dwc2 remains loaded; refusing an invalid stock-matching test"
	sync
	exit 1
fi
echo "confirmed: /sys/module/dwc2 is absent"

echo "--- bounded callback-walk control ---"
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
LIMIT=/sys/kernel/debug/rppocket_pm_callback_limit
if [ ! -w "$LIMIT" ]; then
	echo "ERROR: $LIMIT is absent or not writable; refusing an unbounded test"
	sync
	exit 1
fi
echo "confirmed: $LIMIT is writable"

echo "--- power state before ---"
for f in /sys/power/state /sys/power/mem_sleep /sys/power/pm_test \
	 /sys/power/pm_async /sys/power/pm_print_times \
	 /sys/power/pm_debug_messages; do
	[ -e "$f" ] || continue
	echo "--- $f ---"
	cat "$f" 2>&1 || true
done

echo "--- focused dmesg before ---"
dmesg | grep -iE 'mali|gpu|dwc2|genpd|clk_gpu|pstore|ramoops|callback-walk' | tail -300

[ ! -w /sys/power/pm_async ] || echo 0 > /sys/power/pm_async
[ ! -w /sys/power/pm_print_times ] || echo 1 > /sys/power/pm_print_times
[ ! -w /sys/power/pm_debug_messages ] || echo 1 > /sys/power/pm_debug_messages
echo devices > /sys/power/pm_test
echo "=== armed serialized bounded callback walk ==="
cat /sys/power/pm_test
printf 'pm_async='; cat /sys/power/pm_async 2>&1 || true
sync

# The first walk proved indices 0..462 safe and hung when index 463,
# 0-0020/rk8xx-i2c, was allowed. Resume there after applying the vendor RK817
# sleep-pin sequencing so the synced line below both retests that callback and
# names any later blocker without replaying hundreds of known-safe trials.
previous="index=463 phase=suspend device=0-0020 driver=rk8xx-i2c"
limit=464
while [ "$limit" -le 1024 ]; do
	echo
	echo "=== callback-walk trial limit=$limit ==="
	if [ -n "$previous" ]; then
		echo "ABOUT TO ALLOW PREVIOUSLY BLOCKED ENTRY: $previous"
	fi
	echo "$limit" > "$LIMIT"

	# Visible progress: short blue pulse per safely bounded trial. The LED
	# becoming solid identifies the trial that no longer returned.
	if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.03
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
	fi

	sync
	echo "writing freeze with callback limit $limit"
	date
	echo freeze > /sys/power/state
	status=$?
	echo "state write returned status=$status for limit=$limit"

	candidate="$(dmesg | grep "RPPDBG callback-walk stop index=${limit} " | tail -1)"
	if [ -z "$candidate" ]; then
		echo "STOP: no synthetic callback-limit record for returned trial $limit"
		echo "The walk either completed or failed before reaching its boundary."
		dmesg | tail -300
		break
	fi
	echo "BLOCKED SAFELY BEFORE: $candidate"
	previous="$candidate"
	limit=$((limit + 1))
done

echo 4294967295 > "$LIMIT" 2>/dev/null || true
echo none > /sys/power/pm_test 2>/dev/null || true
sync

# Three quick blue flashes mark a completed walk before clean poweroff.
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	for ignored in 1 2 3; do
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.2
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.2
	done
fi

# With the GPU disabled there may be no usable UI. A clean automatic poweroff
# leaves the blue LED dark and the card ready for inspection.
systemctl --no-block poweroff
exit 0
EOF
chmod +x "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
cat > "$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service" <<'EOF'
[Unit]
Description=RPPocket no-GPU device suspend isolation
After=local-fs.target systemd-udev-trigger.service
Before=graphical.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/storage/.config/rppocket-pm-test-devices-no-gpu.sh

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../rppocket-pm-test-devices-no-gpu.service \
	"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service"
rm -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-wdt-pending" \
	"$STORE_MNT/.cache/log/rppocket-pm-callback-walk.log"
touch "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.once" \
	"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
elif (( PM_FREEZE_NO_GPU || PM_FREEZE )); then
mkdir -p "$STORE_MNT/.config/system.d/multi-user.target.wants" \
	"$STORE_MNT/.config/system.d/rocknix.target.wants"
cat > "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-pm-test-devices-no-gpu.once
MODE=/storage/.config/rppocket-pm-test-devices-no-gpu-mode
LOG=/storage/.cache/log/rppocket-pm-freeze.log
LED_GPIO=17

[ -e "$MARK" ] || exit 0
rm -f "$MARK"

if [ ! -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo "$LED_GPIO" > /sys/class/gpio/export 2>/dev/null || true
	sleep 1
fi
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo out > "/sys/class/gpio/gpio${LED_GPIO}/direction" 2>/dev/null || true
	# Five flashes prove that this one-shot headless harness started.
	for ignored in 1 2 3 4 5; do
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
	done
	echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
fi

sleep 45

mkdir -p /storage/.cache/log
: >"$LOG"
exec >>"$LOG" 2>&1

echo "=== RPPocket real freeze/resume test after RK817 sequence fix ==="
date
uname -a

expect_gpu="$(cat "$MODE" 2>/dev/null)"
case "$expect_gpu" in
	expect-present)
		if [ ! -e /dev/mali0 ] || [ ! -d /sys/module/mali_kbase ] || \
		   [ ! -d /sys/bus/platform/devices/ff400000.gpu ]; then
			echo "ERROR: GPU was expected but is not fully present"
			sync
			exit 1
		fi
		echo "confirmed: GPU platform device, Mali module, and /dev/mali0 are present"
		;;
	expect-absent)
		if [ -e /dev/mali0 ] || [ -d /sys/module/mali_kbase ] || \
		   [ -d /sys/bus/platform/devices/ff400000.gpu ]; then
			echo "ERROR: GPU isolation is not active"
			sync
			exit 1
		fi
		echo "confirmed: GPU device and Mali module are absent"
		;;
	*)
		echo "ERROR: invalid GPU expectation in $MODE: $expect_gpu"
		sync
		exit 1
		;;
esac

lsmod | grep -E '^dwc2([[:space:]]|$)' || echo "dwc2 not listed"
if [ -d /sys/module/dwc2 ]; then
	modprobe -r dwc2
	echo "modprobe -r dwc2 status: $?"
fi
if [ -d /sys/module/dwc2 ]; then
	echo "ERROR: dwc2 remains loaded; refusing this test"
	sync
	exit 1
fi
echo "confirmed: /sys/module/dwc2 is absent"

# The callback walker defaults disabled, but force its U32_MAX sentinel before
# this unbounded test in case debugfs retained an unexpected value.
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
LIMIT=/sys/kernel/debug/rppocket_pm_callback_limit
if [ ! -w "$LIMIT" ]; then
	echo "ERROR: $LIMIT is absent or not writable"
	sync
	exit 1
fi
echo 4294967295 > "$LIMIT"
echo none > /sys/power/pm_test
[ ! -w /sys/power/pm_async ] || echo 0 > /sys/power/pm_async
[ ! -w /sys/power/pm_print_times ] || echo 1 > /sys/power/pm_print_times
[ ! -w /sys/power/pm_debug_messages ] || echo 1 > /sys/power/pm_debug_messages

for f in /sys/power/state /sys/power/mem_sleep /sys/power/pm_test \
	 /sys/power/pm_async; do
	printf '%s: ' "$f"
	cat "$f" 2>&1 || true
done

if ! command -v systemd-inhibit >/dev/null 2>&1; then
	echo "ERROR: systemd-inhibit unavailable; refusing wake-key test"
	sync
	exit 1
fi

echo "ABOUT TO ENTER REAL FREEZE; LED will turn off until resume"
date
sync

# Prevent the wake event from reaching logind as a second suspend request.
# Turning the LED off inside the inhibited child gives the user an exact signal
# that the direct state write is imminent.
systemd-inhibit --what=handle-power-key --mode=block \
	--who=rppocket-pm-freeze --why='single power-slider wake test' \
	sh -c '
		echo 0 > /sys/class/gpio/gpio17/value 2>/dev/null || true
		sync
		echo freeze > /sys/power/state
	'
status=$?

echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
echo "REAL FREEZE RETURNED status=$status"
date
dmesg | tail -400
sync

# Three flashes and automatic poweroff mean the state write returned.
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	for ignored in 1 2 3; do
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.2
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.2
	done
fi
systemctl --no-block poweroff
exit 0
EOF
chmod +x "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
if (( PM_FREEZE )); then
cat > "$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service" <<'EOF'
[Unit]
Description=RPPocket GPU-present real freeze/resume test
After=local-fs.target systemd-logind.service rocknix-autostart.service

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/storage/.config/rppocket-pm-test-devices-no-gpu.sh

[Install]
WantedBy=rocknix.target
EOF
	rm -f "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service"
	ln -sf ../rppocket-pm-test-devices-no-gpu.service \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-test-devices-no-gpu.service"
else
cat > "$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service" <<'EOF'
[Unit]
Description=RPPocket no-GPU real freeze/resume test
After=local-fs.target systemd-udev-trigger.service systemd-logind.service
Before=graphical.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/storage/.config/rppocket-pm-test-devices-no-gpu.sh

[Install]
WantedBy=multi-user.target
EOF
	rm -f "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-test-devices-no-gpu.service"
	ln -sf ../rppocket-pm-test-devices-no-gpu.service \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service"
fi
rm -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-wdt-pending" \
	"$STORE_MNT/.cache/log/rppocket-pm-callback-walk.log" \
	"$STORE_MNT/.cache/log/rppocket-pm-freeze-no-gpu.log" \
	"$STORE_MNT/.cache/log/rppocket-pm-freeze.log"
touch "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.once"
if (( PM_FREEZE )); then
	echo expect-present > "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
else
	echo expect-absent > "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
fi
else
	rm -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh" \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.once" \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode" \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-wdt-pending" \
		"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-test-devices-no-gpu.service"
fi

if (( PM_DEEP )); then
mkdir -p "$STORE_MNT/.config/system.d/rocknix.target.wants" \
	"$STORE_MNT/.config/system.d/multi-user.target.wants"
cat > "$STORE_MNT/.config/rppocket-pm-deep.sh" <<'EOF'
#!/bin/sh

MARK=/storage/.config/rppocket-pm-deep.once
LOG=/storage/.cache/log/rppocket-pm-deep.log
LED_GPIO=17

[ -e "$MARK" ] || exit 0
rm -f "$MARK"

if [ ! -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo "$LED_GPIO" > /sys/class/gpio/export 2>/dev/null || true
	sleep 1
fi
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	echo out > "/sys/class/gpio/gpio${LED_GPIO}/direction" 2>/dev/null || true
	# Five flashes prove that this one-shot headless harness started.
	for ignored in 1 2 3 4 5; do
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.15
	done
	echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
fi

sleep 45

mkdir -p /storage/.cache/log
: >"$LOG"
exec >>"$LOG" 2>&1

echo "=== RPPocket stock-policy deep suspend/resume test ==="
date
uname -a

if [ ! -e /dev/mali0 ] || [ ! -d /sys/module/mali_kbase ] || \
   [ ! -d /sys/bus/platform/devices/ff400000.gpu ]; then
	echo "ERROR: GPU was expected but is not fully present"
	sync
	exit 1
fi
echo "confirmed: GPU platform device, Mali module, and /dev/mali0 are present"

if [ ! -L /sys/bus/platform/devices/rockchip-suspend/driver ]; then
	echo "ERROR: rockchip-suspend is not bound to its BL31 policy driver"
	sync
	exit 1
fi
echo "confirmed: rockchip-suspend BL31 policy driver is bound"

lsmod | grep -E '^dwc2([[:space:]]|$)' || echo "dwc2 not listed"
if [ -d /sys/module/dwc2 ]; then
	modprobe -r dwc2
	echo "modprobe -r dwc2 status: $?"
fi
if [ -d /sys/module/dwc2 ]; then
	echo "ERROR: dwc2 remains loaded; refusing this test"
	sync
	exit 1
fi
echo "confirmed: /sys/module/dwc2 is absent"

mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
LIMIT=/sys/kernel/debug/rppocket_pm_callback_limit
if [ ! -w "$LIMIT" ]; then
	echo "ERROR: $LIMIT is absent or not writable"
	sync
	exit 1
fi
echo 4294967295 > "$LIMIT"
echo none > /sys/power/pm_test
[ ! -w /sys/power/pm_async ] || echo 0 > /sys/power/pm_async
[ ! -w /sys/power/pm_print_times ] || echo 1 > /sys/power/pm_print_times
[ ! -w /sys/power/pm_debug_messages ] || echo 1 > /sys/power/pm_debug_messages

if ! grep -qw mem /sys/power/state; then
	echo "ERROR: mem is unavailable in /sys/power/state"
	sync
	exit 1
fi
if ! tr '[]' '  ' < /sys/power/mem_sleep | grep -qw deep; then
	echo "ERROR: deep is unavailable in /sys/power/mem_sleep"
	sync
	exit 1
fi
echo deep > /sys/power/mem_sleep
if ! grep -q '\[deep\]' /sys/power/mem_sleep; then
	echo "ERROR: failed to select deep mem_sleep"
	sync
	exit 1
fi

for f in /sys/power/state /sys/power/mem_sleep /sys/power/pm_test \
	 /sys/power/pm_async; do
	printf '%s: ' "$f"
	cat "$f" 2>&1 || true
done

if ! command -v systemd-inhibit >/dev/null 2>&1; then
	echo "ERROR: systemd-inhibit unavailable; refusing wake-key test"
	sync
	exit 1
fi

echo "ABOUT TO ENTER DEEP MEM; LED will turn off until resume"
date
sync

# Keep the wake event from reaching logind as a second suspend request.
systemd-inhibit --what=handle-power-key --mode=block \
	--who=rppocket-pm-deep --why='single power-slider deep wake test' \
	sh -c '
		echo 0 > /sys/class/gpio/gpio17/value 2>/dev/null || true
		sync
		echo mem > /sys/power/state
	'
status=$?

echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
echo "DEEP MEM RETURNED status=$status"
date
dmesg | tail -600
sync

# Three flashes and automatic poweroff mean the state write returned.
if [ -d "/sys/class/gpio/gpio${LED_GPIO}" ]; then
	for ignored in 1 2 3; do
		echo 0 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.2
		echo 1 > "/sys/class/gpio/gpio${LED_GPIO}/value" 2>/dev/null || true
		sleep 0.2
	done
fi
systemctl --no-block poweroff
exit 0
EOF
chmod +x "$STORE_MNT/.config/rppocket-pm-deep.sh"
cat > "$STORE_MNT/.config/system.d/rppocket-pm-deep.service" <<'EOF'
[Unit]
Description=RPPocket stock-policy deep suspend/resume test
After=local-fs.target systemd-logind.service rocknix-autostart.service

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/storage/.config/rppocket-pm-deep.sh

[Install]
WantedBy=rocknix.target
EOF
rm -f "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-deep.service"
ln -sf ../rppocket-pm-deep.service \
	"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service"
rm -f "$STORE_MNT/.cache/log/rppocket-pm-deep.log"
touch "$STORE_MNT/.config/rppocket-pm-deep.once"
else
	rm -f "$STORE_MNT/.config/rppocket-pm-deep.sh" \
		"$STORE_MNT/.config/rppocket-pm-deep.once" \
		"$STORE_MNT/.config/system.d/rppocket-pm-deep.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-deep.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service"
fi

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

	echo "confirmed: passive collector active; no debug PM initiator or broad hook"
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

if (( POWER_SLIDER_CLEANUP )); then
	rm -f "$STORE_MNT/.config/autostart/000-rppocket-debug.sh" \
		"$STORE_MNT/.config/rppocket-no-dwc2-rebind" \
		"$STORE_MNT/.config/rppocket-pm-test-install.manifest" \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh" \
		"$STORE_MNT/.config/rppocket-power-slider-reliability-test.once" \
		"$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service" \
		"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-test.log" \
		"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log" \
		"$STORE_MNT/.cache/log/rppocket-power-slider-reliability-v1-journal.log"
fi

if (( WIFI_RAIL_SCAN )); then
cat > "$STORE_MNT/.config/autostart/010-rppocket-wifi-rail-scan.sh" <<'EOF'
#!/bin/sh
# Manual rail-identification helper.  It drives the remaining stock-derived,
# currently-unproven GPIO candidates one at a time so the YJ33 EN/output rail
# can be measured without rebuilding for every GPIO.

OUT=/flash
LOG="$OUT/rppocket-wifi-rail-scan.txt"
CUR="$OUT/rppocket-wifi-rail-scan-current.txt"

export_gpio() {
	gpio="$1"
	if [ ! -d "/sys/class/gpio/gpio${gpio}" ]; then
		echo "$gpio" > /sys/class/gpio/export 2>/dev/null || return 1
		sleep 0.2
	fi
	echo 0 > "/sys/class/gpio/gpio${gpio}/active_low" 2>/dev/null || true
	return 0
}

mark_state() {
	text="$1"
	mount -o remount,rw "$OUT" 2>/dev/null || true
	echo "$(date +%s) ${text}" >> "$LOG" 2>/dev/null || true
	echo "$text" > "$CUR" 2>/dev/null || true
}

drive_gpio() {
	gpio="$1"
	value="$2"
	label="$3"

	mark_state "begin ${label}: gpio${gpio}=physical-${value}"

	if ! export_gpio "$gpio"; then
		mark_state "${label} gpio${gpio}: export failed"
		return
	fi

	echo out > "/sys/class/gpio/gpio${gpio}/direction" 2>/dev/null || true
	echo "$value" > "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || true
	actual="$(cat "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || echo "?")"
	mark_state "${label}: gpio${gpio}=physical-${value} actual=${actual}"
	sleep 30
}

drive_all_stock_low() {
	label="stock AMUX all PB0/PB3/PB5 low"
	hold="${1:-30}"

	mark_state "begin ${label}"
	for gpio in 96 99 101; do
		export_gpio "$gpio" || true
		echo out > "/sys/class/gpio/gpio${gpio}/direction" 2>/dev/null || true
		echo 0 > "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || true
	done
	actual96="$(cat /sys/class/gpio/gpio96/value 2>/dev/null || echo "?")"
	actual99="$(cat /sys/class/gpio/gpio99/value 2>/dev/null || echo "?")"
	actual101="$(cat /sys/class/gpio/gpio101/value 2>/dev/null || echo "?")"
	mark_state "${label}: gpio96=${actual96} gpio99=${actual99} gpio101=${actual101} hold=${hold}s"
	sleep "$hold"
}

(
	mount -o remount,rw "$OUT" 2>/dev/null || true
	{
		echo "RPPocket Wi-Fi rail scan"
		echo "Measure YT1/E1-T/YB2 while each line is active."
		echo "GPIO0_PA0 and GPIO2_PB1 already tested negative."
		echo "Each remaining state lasts 30 seconds. Physical value is raw GPIO level."
		echo
	} > "$LOG"

	drive_gpio 67 1 "candidate-c stock bat_low GPIO2_PA3 high"
	drive_gpio 67 0 "candidate-c stock bat_low GPIO2_PA3 low"
	drive_gpio 15 1 "candidate-d stock-comment vcc_host GPIO0_PB7 high"
	drive_gpio 15 0 "candidate-d stock-comment vcc_host GPIO0_PB7 low"

	echo "done" > "$CUR"
	echo "$(date +%s) done" >> "$LOG"
	sync
	mount -o remount,ro "$OUT" 2>/dev/null || true
) &
EOF
chmod +x "$STORE_MNT/.config/autostart/010-rppocket-wifi-rail-scan.sh"
else
	rm -f "$STORE_MNT/.config/autostart/010-rppocket-wifi-rail-scan.sh"
fi

if (( RK817_GPIO_SCAN )); then
cat > "$STORE_MNT/.config/autostart/011-rppocket-rk817-gpio-scan.sh" <<'EOF'
#!/bin/sh
# Manual RK817 GPIO identification helper.  It tries PMIC TS/GT GPIO output
# states through RK817_GPIO_INT_CFG (0xfe) so the YJ33 EN/output rail can be
# measured without a kernel rebuild.

OUT=/flash
LOG="$OUT/rppocket-rk817-gpio-scan.txt"
CUR="$OUT/rppocket-rk817-gpio-scan-current.txt"
BUS=0
ADDR=0x20
REG=0xfe

hex_to_dec() {
	printf "%d" "$1" 2>/dev/null || printf "0"
}

read_reg() {
	i2cget -f -y "$BUS" "$ADDR" "$REG" 2>/dev/null || echo "0x00"
}

write_reg() {
	label="$1"
	value="$2"

	echo "$(date +%s) begin ${label}: RK817[0xfe]=${value}" >> "$LOG"
	echo "begin ${label}: RK817[0xfe]=${value}" > "$CUR"
	i2cset -f -y "$BUS" "$ADDR" "$REG" "$value" 2>> "$LOG" || true
	actual="$(read_reg)"
	echo "$(date +%s) ${label}: actual=${actual}" >> "$LOG"
	echo "${label}: RK817[0xfe]=${actual}" > "$CUR"
	sleep 30
}

(
	mount -o remount,rw "$OUT" 2>/dev/null || true
	{
		echo "RPPocket RK817 GPIO scan"
		echo "Measure E1-T/YT1/YB2-W1/X2/X3 during each 30s state."
		echo "TS high means bits func/value/dir = 0x1c."
		echo "GT high means bits func/value/dir = 0xe0."
		echo
	} > "$LOG"

	if ! command -v i2cget >/dev/null 2>&1 || ! command -v i2cset >/dev/null 2>&1; then
		echo "i2cget/i2cset unavailable" >> "$LOG"
		echo "i2c tools unavailable" > "$CUR"
		exit 0
	fi

	BEFORE="$(read_reg)"
	ORIG_DEC=0x20
	echo "$(date +%s) initial RK817[0xfe]=${BEFORE}" >> "$LOG"
	echo "$(date +%s) baseline RK817[0xfe]=0x20" >> "$LOG"

	TS_HIGH_DEC=$(( (ORIG_DEC & ~0x1c) | 0x1c ))
	GT_HIGH_DEC=$(( (ORIG_DEC & ~0xe0) | 0xe0 ))
	BOTH_HIGH_DEC=$(( (ORIG_DEC & ~0xfc) | 0xfc ))

	write_reg "baseline hold" "$(printf '0x%02x' "$ORIG_DEC")"
	write_reg "PMIC gpio_ts output high" "$(printf '0x%02x' "$TS_HIGH_DEC")"
	write_reg "PMIC gpio_gt output high" "$(printf '0x%02x' "$GT_HIGH_DEC")"
	write_reg "PMIC gpio_ts and gpio_gt output high" "$(printf '0x%02x' "$BOTH_HIGH_DEC")"
	write_reg "restore baseline" "$(printf '0x%02x' "$ORIG_DEC")"

	echo "done" > "$CUR"
	echo "$(date +%s) done" >> "$LOG"
	sync
	mount -o remount,ro "$OUT" 2>/dev/null || true
) &
EOF
chmod +x "$STORE_MNT/.config/autostart/011-rppocket-rk817-gpio-scan.sh"
else
	rm -f "$STORE_MNT/.config/autostart/011-rppocket-rk817-gpio-scan.sh"
fi

if (( AMUX_GPIO_SCAN )); then
cat > "$STORE_MNT/.config/autostart/012-rppocket-amux-gpio-scan.sh" <<'EOF'
#!/bin/sh
# Manual stock-AMUX GPIO identification helper.  The stock odroidgo3-joypad
# driver requests GPIO3_PB0/PB3/PB5 and drives them raw low during probe.
# ROCKNIX does not currently claim these lines.

OUT=/flash
LOG="$OUT/rppocket-amux-gpio-scan.txt"
CUR="$OUT/rppocket-amux-gpio-scan-current.txt"

export_gpio() {
	gpio="$1"
	if [ ! -d "/sys/class/gpio/gpio${gpio}" ]; then
		echo "$gpio" > /sys/class/gpio/export 2>/dev/null || return 1
		sleep 0.2
	fi
	echo 0 > "/sys/class/gpio/gpio${gpio}/active_low" 2>/dev/null || true
	return 0
}

mark_state() {
	text="$1"
	mount -o remount,rw "$OUT" 2>/dev/null || true
	echo "$(date +%s) ${text}" >> "$LOG" 2>/dev/null || true
	echo "$text" > "$CUR" 2>/dev/null || true
}

drive_gpio() {
	gpio="$1"
	value="$2"
	label="$3"

	mark_state "begin ${label}: gpio${gpio}=physical-${value}"

	if ! export_gpio "$gpio"; then
		mark_state "${label} gpio${gpio}: export failed"
		return
	fi

	echo out > "/sys/class/gpio/gpio${gpio}/direction" 2>/dev/null || true
	echo "$value" > "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || true
	actual="$(cat "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || echo "?")"
	mark_state "${label}: gpio${gpio}=physical-${value} actual=${actual}"
	sleep 30
}

drive_all_stock_low() {
	label="stock AMUX all PB0/PB3/PB5 low"

	mark_state "begin ${label}"
	for gpio in 96 99 101; do
		export_gpio "$gpio" || true
		echo out > "/sys/class/gpio/gpio${gpio}/direction" 2>/dev/null || true
		echo 0 > "/sys/class/gpio/gpio${gpio}/value" 2>/dev/null || true
	done
	actual96="$(cat /sys/class/gpio/gpio96/value 2>/dev/null || echo "?")"
	actual99="$(cat /sys/class/gpio/gpio99/value 2>/dev/null || echo "?")"
	actual101="$(cat /sys/class/gpio/gpio101/value 2>/dev/null || echo "?")"
	mark_state "${label}: gpio96=${actual96} gpio99=${actual99} gpio101=${actual101}"
	sleep 30
}

(
	mount -o remount,rw "$OUT" 2>/dev/null || true
	{
		echo "RPPocket stock AMUX GPIO scan"
		echo "Measure E1-T/YT1/YB2/W1/X pads during each 30s state."
		echo "Stock odroidgo3-joypad drives GPIO3_PB0/PB3/PB5 raw low."
		echo "GPIO numbers: PB0=96, PB3=99, PB5=101."
		echo
	} > "$LOG"

	drive_all_stock_low 300
	drive_gpio 96 0 "stock AMUX-A GPIO3_PB0 low"
	drive_gpio 96 1 "stock AMUX-A GPIO3_PB0 high"
	drive_gpio 99 0 "stock AMUX-B GPIO3_PB3 low"
	drive_gpio 99 1 "stock AMUX-B GPIO3_PB3 high"
	drive_gpio 101 0 "stock AMUX-EN GPIO3_PB5 low"
	drive_gpio 101 1 "stock AMUX-EN GPIO3_PB5 high"

	mark_state "done"
	sync
	mount -o remount,ro "$OUT" 2>/dev/null || true
) &
EOF
chmod +x "$STORE_MNT/.config/autostart/012-rppocket-amux-gpio-scan.sh"
else
	rm -f "$STORE_MNT/.config/autostart/012-rppocket-amux-gpio-scan.sh"
fi

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

# Do not report a prepared PM test unless every storage-backed component is
# present and internally consistent. The user keeps the card in the host after
# this step so the agent can independently inspect these files before boot.
rm -f "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
if (( PM_TEST_DEVICES )); then
	test -x "$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh"
	test -f "$STORE_MNT/.config/rppocket-pm-test-devices.once"
	test -f "$STORE_MNT/.config/rppocket-pm-test-devices-mode"
	{
		echo "harness=rppocket-pm-test-devices-v1"
		sha256sum "$STORE_MNT/.config/autostart/001-rppocket-pm-test-devices.sh"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
	echo ">>> VERIFIED: direct device PM-test hook, marker, and mode are installed."
elif (( PM_TEST_DEVICES_NO_GPU )); then
	test -x "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	test -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.once"
	test -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
	test -f "$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
	test -L "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service"
	test "$(readlink "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service")" = \
		"../rppocket-pm-test-devices-no-gpu.service"
	test ! -e "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-wdt-pending"
	grep -q 'bounded callback-walk control' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'ABOUT TO ALLOW PREVIOUSLY BLOCKED ENTRY' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q '^limit=464$' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'previous="index=463 phase=suspend device=0-0020 driver=rk8xx-i2c"' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	{
		echo "harness=rppocket-no-gpu-rk817-fix-walk-v3"
		sha256sum \
			"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh" \
			"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
		echo "service_link=../rppocket-pm-test-devices-no-gpu.service"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
	echo ">>> VERIFIED: no-GPU callback-walk service, script, markers, and link are installed."
elif (( PM_FREEZE_NO_GPU || PM_FREEZE )); then
	test -x "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	test -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.once"
	test -f "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
	test -f "$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
	if (( PM_FREEZE )); then
		service_target=rocknix.target
		test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-test-devices-no-gpu.service"
		grep -q '^After=.*rocknix-autostart.service' \
			"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
		grep -qx 'WantedBy=rocknix.target' \
			"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
	else
		service_target=multi-user.target
		test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-test-devices-no-gpu.service"
		grep -qx 'Before=graphical.target' \
			"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
		grep -qx 'WantedBy=multi-user.target' \
			"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
	fi
	service_link="$STORE_MNT/.config/system.d/$service_target.wants/rppocket-pm-test-devices-no-gpu.service"
	test -L "$service_link"
	test "$(readlink "$service_link")" = "../rppocket-pm-test-devices-no-gpu.service"
	test ! -e "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-wdt-pending"
	test ! -e "$STORE_MNT/.cache/log/rppocket-pm-callback-walk.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-pm-freeze-no-gpu.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-pm-freeze.log"
	if (( PM_FREEZE )); then
		grep -qx 'expect-present' "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
	else
		grep -qx 'expect-absent' "$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu-mode"
	fi
	grep -q 'real freeze/resume test after RK817 sequence fix' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'ABOUT TO ENTER REAL FREEZE' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'systemd-inhibit --what=handle-power-key --mode=block' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'echo 4294967295 > "$LIMIT"' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'echo none > /sys/power/pm_test' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'echo 0 > /sys/power/pm_async' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	grep -q 'echo freeze > /sys/power/state' \
		"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh"
	{
		if (( PM_FREEZE )); then
			echo "harness=rppocket-gpu-real-freeze-v7"
		else
			echo "harness=rppocket-no-gpu-real-freeze-v6"
		fi
		sha256sum \
			"$STORE_MNT/.config/rppocket-pm-test-devices-no-gpu.sh" \
			"$STORE_MNT/.config/system.d/rppocket-pm-test-devices-no-gpu.service"
		echo "service_target=$service_target"
		echo "service_link=../rppocket-pm-test-devices-no-gpu.service"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
	echo ">>> VERIFIED: real-freeze service, GPU expectation, script, markers, and link are installed."
elif (( PM_DEEP )); then
	test -x "$STORE_MNT/.config/rppocket-pm-deep.sh"
	test -f "$STORE_MNT/.config/rppocket-pm-deep.once"
	test -f "$STORE_MNT/.config/system.d/rppocket-pm-deep.service"
	test -L "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service"
	test "$(readlink "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service")" = \
		"../rppocket-pm-deep.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-pm-deep.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-test-devices-no-gpu.service"
	test ! -e "$STORE_MNT/.cache/log/rppocket-pm-deep.log"
	grep -qx 'Description=RPPocket stock-policy deep suspend/resume test' \
		"$STORE_MNT/.config/system.d/rppocket-pm-deep.service"
	grep -q '^After=.*rocknix-autostart.service' \
		"$STORE_MNT/.config/system.d/rppocket-pm-deep.service"
	grep -qx 'TimeoutStartSec=infinity' \
		"$STORE_MNT/.config/system.d/rppocket-pm-deep.service"
	grep -qx 'WantedBy=rocknix.target' \
		"$STORE_MNT/.config/system.d/rppocket-pm-deep.service"
	grep -q 'GPU was expected but is not fully present' \
		"$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'rockchip-suspend BL31 policy driver is bound' \
		"$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'modprobe -r dwc2' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'echo 4294967295 > "$LIMIT"' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'echo none > /sys/power/pm_test' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'echo 0 > /sys/power/pm_async' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'echo deep > /sys/power/mem_sleep' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'systemd-inhibit --what=handle-power-key --mode=block' \
		"$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'echo mem > /sys/power/state' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q 'DEEP MEM RETURNED status=' "$STORE_MNT/.config/rppocket-pm-deep.sh"
	grep -q '/storage/.config/rppocket-pm-deep.once' \
		"$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
	{
		echo "harness=rppocket-stock-policy-deep-v2"
		sha256sum \
			"$STORE_MNT/.config/rppocket-pm-deep.sh" \
			"$STORE_MNT/.config/system.d/rppocket-pm-deep.service" \
			"$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
		echo "service_target=rocknix.target"
		echo "service_link=../rppocket-pm-deep.service"
		date -u +prepared_utc=%Y-%m-%dT%H:%M:%SZ
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
	echo ">>> VERIFIED: deep-mem service, marker, controls, and link are installed."
elif (( POWER_SLIDER_TEST )); then
	test -x "$STORE_MNT/.config/rppocket-power-slider-test.sh"
	test -f "$STORE_MNT/.config/rppocket-power-slider-test.once"
	test -f "$STORE_MNT/.config/system.d/rppocket-power-slider-test.service"
	test -L "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service"
	test "$(readlink "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-test.service")" = \
		"../rppocket-power-slider-test.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-test.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-test-devices-no-gpu.service"
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
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
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
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service"
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
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
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
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-pm-deep.service"
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
	grep -q 'no debug PM initiator or broad hook' \
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
	} > "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
	echo ">>> VERIFIED: passive reliability collector is sole service; broad debug is absent."
elif (( POWER_SLIDER_CLEANUP )); then
	test ! -e "$STORE_MNT/.config/autostart/000-rppocket-debug.sh"
	test ! -e "$STORE_MNT/.config/rppocket-no-dwc2-rebind"
	test ! -e "$STORE_MNT/.config/rppocket-pm-test-install.manifest"
	test ! -e "$STORE_MNT/.config/rppocket-power-slider-reliability-test.sh"
	test ! -e "$STORE_MNT/.config/rppocket-power-slider-reliability-test.once"
	test ! -e "$STORE_MNT/.config/system.d/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.config/system.d/rocknix.target.wants/rppocket-power-slider-reliability-test.service"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-test.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-orderly-shutdown.log"
	test ! -e "$STORE_MNT/.cache/log/rppocket-power-slider-reliability-v1-journal.log"
	if find "$STORE_MNT/.config/system.d" -maxdepth 2 -type l \
		-name 'rppocket-*' -print -quit | grep -q .; then
		echo "ERROR: an RPPocket test service link remains" >&2
		exit 1
	fi
	echo ">>> VERIFIED: storage-side power-slider diagnostics are removed."
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

if (( PM_TEST_DEVICES || PM_TEST_DEVICES_NO_GPU || PM_FREEZE_NO_GPU || PM_FREEZE || PM_DEEP || POWER_SLIDER_TEST || POWER_SLIDER_LONG_TEST || POWER_SLIDER_RELIABILITY_TEST || POWER_SLIDER_CLEANUP )); then
	echo ">>> PREPARED, NOT CLEARED TO BOOT: leave the card in this PC."
	echo ">>> Tell the agent 'prepared' so the image and harness can be verified read-only."
else
	echo ">>> OK. Insert SD into RPPocket and power on."
fi
if (( PM_TEST_DEVICES )); then
	echo ">>> After verification: do not operate the slider; test starts after ~45 sec."
	echo ">>> A blocked callback should panic after 20 sec and reboot 1 sec later."
	echo ">>> After the UI returns, wait ~1 min, shut down from the menu,"
	echo ">>> reinsert the SD, and tell the agent it is inserted."
elif (( PM_TEST_DEVICES_NO_GPU )); then
	echo ">>> This image intentionally has no GPU, so the UI may never appear."
	echo ">>> Five rapid blue flashes prove the headless harness actually started."
	echo ">>> If they are not seen within 30 sec, power off; do not continue waiting."
	echo ">>> At ~45 sec, dim pulses continue the walk from the fixed RK817 callback."
	echo ">>> When pulsing stops and blue stays solid for 30 sec, the blocker is named"
	echo ">>> in the synced log. Shut down with the usual long hold and reinsert the SD."
	echo ">>> If it flashes 3 times and powers off itself, simply reinsert the SD."
elif (( PM_FREEZE_NO_GPU || PM_FREEZE )); then
	if (( PM_FREEZE )); then
		echo ">>> GPU startup runs first; five rapid blue flashes should appear within 90 sec."
	else
		echo ">>> Five rapid blue flashes prove startup; stop if absent within 30 sec."
	fi
	echo ">>> About 45 sec after those flashes, blue turns off immediately before real freeze."
	echo ">>> Once it is off, use one short power-slider action to request wake."
	echo ">>> Three flashes and automatic poweroff prove the state write returned."
	echo ">>> Otherwise wait 2 min, force fully off, and reinsert the card."
elif (( PM_DEEP )); then
	echo ">>> GPU startup runs first; five rapid blue flashes should appear within 90 sec."
	echo ">>> About 45 sec later, blue turns off immediately before deep mem suspend."
	echo ">>> Once it is off, use one short power-slider action to request wake."
	echo ">>> Three flashes and automatic poweroff prove deep mem returned."
	echo ">>> Otherwise wait 2 min, force fully off, and reinsert the card."
elif (( POWER_SLIDER_TEST )); then
	echo ">>> Five rapid blue flashes within 90 sec prove production policy is active."
	echo ">>> Then perform only the separately requested short-action test."
elif (( POWER_SLIDER_LONG_TEST )); then
	echo ">>> Five rapid blue flashes within 90 sec prove long-press policy is active."
	echo ">>> Then hold continuously and release as soon as shutdown visibly begins."
elif (( POWER_SLIDER_RELIABILITY_TEST )); then
	echo ">>> Wait 90 sec for normal startup, then perform ten requested short cycles."
	echo ">>> Only the passive shutdown journal collector remains active."
elif (( POWER_SLIDER_CLEANUP )); then
	echo ">>> Production storage is clean; no further hardware test is required."
else
	echo ">>> Wait ~3 min (or until the blinking LED stops changing cadence),"
	echo ">>> power off with a long press, pull the SD, and tell the agent it is inserted."
fi
if (( DWC2_REBIND )); then
	echo ">>> Late hook will run the DWC2 unbind/rebind experiment."
else
	echo ">>> Late hook will skip the DWC2 unbind/rebind experiment."
fi
echo
if (( FLASH )); then
	echo "    (Flashed from $(basename "$IMG"))"
fi
