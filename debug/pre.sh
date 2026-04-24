#!/bin/bash
# Install debugging hooks onto the ROCKNIX SD card before boot:
#   - persistent journald storage
#   - a systemd oneshot that dumps dmesg/lsmod/drm names to the boot partition
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
	echo "Refusing to touch $DEV — it is ${SIZE_GB} GB, which looks too large for the RPPocket SD card." >&2
	echo "If this really is the SD, re-run after manually editing the size gate in $0." >&2
	exit 1
fi

echo ">>> Target: $DEV (${SIZE_GB} GB).  Press Ctrl-C within 3s to abort."
sleep 3

cleanup() { umount "$STORE_MNT" 2>/dev/null || true; umount "$BOOT_MNT" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$BOOT_MNT" "$STORE_MNT"
umount "${DEV}1" 2>/dev/null || true
umount "${DEV}2" 2>/dev/null || true

mount "${DEV}2" "$STORE_MNT"

# 1) Persistent journald
mkdir -p "$STORE_MNT/.config/journald.conf.d"
cat > "$STORE_MNT/.config/journald.conf.d/persist.conf" <<'EOF'
[Journal]
Storage=persistent
ForwardToConsole=yes
EOF

# 2) Oneshot service that dumps diagnostics to the FAT boot partition (/flash)
mkdir -p "$STORE_MNT/.config/system.d"
cat > "$STORE_MNT/.config/system.d/rppocket-dbg.service" <<'EOF'
[Unit]
Description=Capture dmesg/lsmod/drm names to /flash for headless debugging
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'dmesg > /flash/dmesg-boot.txt 2>&1; lsmod > /flash/lsmod.txt 2>&1; for f in /sys/kernel/debug/dri/*/name; do echo "== $f =="; cat "$f"; done > /flash/drm-names.txt 2>&1; journalctl -b --no-pager > /flash/journalctl-boot.txt 2>&1; sync'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$STORE_MNT/.config/system.d/multi-user.target.wants"
ln -sf ../rppocket-dbg.service \
	"$STORE_MNT/.config/system.d/multi-user.target.wants/rppocket-dbg.service"

# 3) Clear stale debug artefacts on boot partition so a failed boot is obvious
umount "$STORE_MNT"
mount "${DEV}1" "$BOOT_MNT"
rm -f "$BOOT_MNT/dmesg-boot.txt" "$BOOT_MNT/lsmod.txt" \
	"$BOOT_MNT/drm-names.txt" "$BOOT_MNT/journalctl-boot.txt" \
	"$BOOT_MNT/error.log"
sync
umount "$BOOT_MNT"

echo ">>> OK. SD is prepped. Insert into RPPocket and power on."
echo ">>> After ~3 min (or when the blinking LED settles), power off and run post.sh."
