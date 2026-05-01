#!/bin/bash
# SDWire3 helper for RPPocket bring-up.
#
# Examples:
#   sudo ./debug/sdwire-load.sh list
#   sudo ./debug/sdwire-load.sh host
#   sudo ./debug/sdwire-load.sh target
#   sudo ./debug/sdwire-load.sh rocknix --dev /dev/sdX
#   sudo ./debug/sdwire-load.sh stock --dev /dev/sdX
#   sudo ./debug/sdwire-load.sh stock --image debug/v1.1.3-stock-debug-4g.img --dev /dev/sdX
#
# The sdwire CLI uses:
#   host/ts     connect card to this Linux host for flashing/inspection
#   target/dut connect card back to the RPPocket
#   off        disconnect card from both sides

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SDWIRE="${SDWIRE:-sdwire}"

if ! command -v "$SDWIRE" >/dev/null 2>&1 && [[ "$SDWIRE" == "sdwire" && -n "${SUDO_USER:-}" ]]; then
	USER_SDWIRE="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/bin/sdwire"
	if [[ -x "$USER_SDWIRE" ]]; then
		SDWIRE="$USER_SDWIRE"
	fi
fi

SERIAL=""
DEV=""
IMAGE=""
SWITCH_TARGET=1
PASS_PRE=()

usage() {
	cat <<EOF
Usage:
  sudo $0 list
  sudo $0 host|target|off [--serial SERIAL]
  sudo $0 rocknix [--dev /dev/sdX] [--serial SERIAL] [--no-target] [--no-dwc2-rebind]
  sudo $0 stock   [--dev /dev/sdX] [--image PATH] [--serial SERIAL] [--no-target]

Notes:
  rocknix flashes the newest target/ROCKNIX-*.aarch64-*-a.img.gz via debug/pre.sh.
  stock flashes debug/v1.1.3-stock-debug-4g.img by default.
  SDWire is switched to host before flashing and target after flashing.
EOF
}

need_sdwire() {
	if ! command -v "$SDWIRE" >/dev/null 2>&1; then
		echo "sdwire CLI not found. Install python3-sdwire/pipx sdwire, or set SDWIRE=/path/to/sdwire." >&2
		exit 1
	fi
}

sdwire_args() {
	if [[ -n "$SERIAL" ]]; then
		printf '%s\n' -s "$SERIAL"
	fi
}

sdwire_switch() {
	local mode="$1"
	need_sdwire
	if [[ -n "$SERIAL" ]]; then
		"$SDWIRE" switch -s "$SERIAL" "$mode"
	else
		"$SDWIRE" switch "$mode"
	fi
}

wait_for_dev() {
	local timeout="${1:-12}"
	local i=0
	while [[ -n "$DEV" && ! -b "$DEV" && "$i" -lt "$timeout" ]]; do
		sleep 1
		i=$((i + 1))
	done
	if [[ -z "$DEV" ]]; then
		echo "No --dev supplied. After switching to host, choose the SD block device:" >&2
		lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,MOUNTPOINTS >&2
		echo "Then rerun with --dev /dev/sdX." >&2
		exit 1
	fi
	if [[ ! -b "$DEV" ]]; then
		echo "Not a block device after host switch: $DEV" >&2
		exit 1
	fi
}

require_root_for_flash() {
	if [[ $EUID -ne 0 ]]; then
		echo "Flashing requires root. Try: sudo $0 $*" >&2
		exit 1
	fi
}

parse_common() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--serial|-s)
				SERIAL="${2:-}"
				[[ -n "$SERIAL" ]] || { echo "--serial needs a value" >&2; exit 1; }
				shift 2
				;;
			--dev)
				DEV="${2:-}"
				[[ -n "$DEV" ]] || { echo "--dev needs a value" >&2; exit 1; }
				shift 2
				;;
			--image)
				IMAGE="${2:-}"
				[[ -n "$IMAGE" ]] || { echo "--image needs a value" >&2; exit 1; }
				shift 2
				;;
			--no-target)
				SWITCH_TARGET=0
				shift
				;;
			--no-dwc2-rebind)
				PASS_PRE+=(--no-dwc2-rebind)
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				echo "Unknown argument: $1" >&2
				usage >&2
				exit 1
				;;
		esac
	done
}

flash_stock() {
	local img="$IMAGE"
	[[ -n "$img" ]] || img="$HERE/v1.1.3-stock-debug-4g.img"
	[[ -f "$img" ]] || { echo "Stock image not found: $img" >&2; exit 1; }

	wait_for_dev
	local size_gb
	size_gb=$(lsblk -bno SIZE "$DEV" | head -1 | awk '{printf "%.0f", $1/1073741824}')
	if [[ "$size_gb" -gt 64 ]]; then
		echo "Refusing to touch $DEV: ${size_gb} GB is too large for the RPPocket SD card." >&2
		exit 1
	fi

	echo ">>> Target: $DEV (${size_gb} GB)"
	echo ">>> Stock:  $img"
	echo ">>> This will WIPE the SD card. Ctrl-C within 5s to abort."
	sleep 5
	umount "${DEV}"?* 2>/dev/null || true
	if [[ "$img" == *.gz ]]; then
		gunzip -c "$img" | dd of="$DEV" bs=4M status=progress conv=fsync
	else
		dd if="$img" of="$DEV" bs=4M status=progress conv=fsync
	fi
	sync
	partprobe "$DEV" 2>/dev/null || true
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage >&2; exit 1; }
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then
	usage
	exit 0
fi
shift || true

case "$cmd" in
	list)
		parse_common "$@"
		need_sdwire
		"$SDWIRE" list
		;;
	host|ts)
		parse_common "$@"
		sdwire_switch host
		;;
	target|dut)
		parse_common "$@"
		sdwire_switch target
		;;
	off)
		parse_common "$@"
		sdwire_switch off
		;;
	rocknix)
		parse_common "$@"
		require_root_for_flash "$cmd" "$@"
		sdwire_switch host
		wait_for_dev
		"$HERE/pre.sh" --flash "$DEV" "${PASS_PRE[@]}"
		(( SWITCH_TARGET )) && sdwire_switch target
		echo ">>> OK. SDWire card is connected to target. Power-cycle the RPPocket."
		;;
	stock)
		parse_common "$@"
		require_root_for_flash "$cmd" "$@"
		sdwire_switch host
		flash_stock
		(( SWITCH_TARGET )) && sdwire_switch target
		echo ">>> OK. SDWire card is connected to target. Power-cycle the RPPocket."
		;;
	*)
		echo "Unknown command: $cmd" >&2
		usage >&2
		exit 1
		;;
esac
