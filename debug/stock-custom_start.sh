#!/bin/sh

OUT="/storage/rppocket-stock-debug-$(date +%s).txt"
RPP_ENABLE_DEVMEM="${RPP_ENABLE_DEVMEM:-1}"

dump_devmem_window() {
  label="$1"
  base="$2"
  words="$3"

  if [ "${RPP_ENABLE_DEVMEM:-0}" != "1" ]; then
    echo "=== devmem ${label} base=${base} words=${words} ==="
    echo "devmem skipped; set RPP_ENABLE_DEVMEM=1 to enable"
    return
  fi

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
  # These are the relevant RK3326/RK817 bring-up blocks for the Wi-Fi rail:
  # PMU GRF, main GRF, GPIO banks, USB2PHY GRF, and DWC2 host controller.
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
  for d in /sys/class/i2c-adapter/i2c-*; do
    [ -d "$d" ] || continue
    printf '%s name=%s\n' "$d" "$(cat "$d/name" 2>/dev/null)"
  done

  echo "--- i2c devices ---"
  for d in /sys/bus/i2c/devices/*; do
    [ -e "$d" ] || continue
    echo "--- $d ---"
    for f in name modalias uevent; do
      [ -e "$d/$f" ] || continue
      printf '%-14s = %s\n' "$f" "$(tr '\n' ' ' <"$d/$f" 2>/dev/null)"
    done
    if [ -L "$d/driver" ]; then
      echo "driver=$(readlink "$d/driver")"
    fi
  done

  echo "--- debugfs regmap rk8xx/rk817/0-0020 ---"
  for d in /sys/kernel/debug/regmap/*; do
    [ -d "$d" ] || continue
    case "$d" in
      *0-0020*|*rk8*|*rk817*) ;;
      *) continue ;;
    esac
    for f in name registers; do
      [ -e "$d/$f" ] || continue
      echo "--- $d/$f ---"
      cat "$d/$f" 2>&1
    done
  done

  echo "--- i2cdetect ---"
  if command -v i2cdetect >/dev/null 2>&1; then
    for d in /dev/i2c-*; do
      [ -e "$d" ] || continue
      bus="${d#/dev/i2c-}"
      echo "--- i2c-${bus} ---"
      i2cdetect -y "$bus" 2>&1 || true
    done
  else
    echo "i2cdetect unavailable"
  fi
}

snap() {
  label="$1"
  {
    echo "===== SNAP ${label} $(date) ====="

    echo "=== uname ==="
    uname -a

    echo "=== cmdline ==="
    cat /proc/cmdline

    echo "=== device tree ==="
    tr '\0' '\n' < /proc/device-tree/model 2>/dev/null || true
    tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null || true

    echo "=== lsmod ==="
    lsmod 2>&1 || true

    echo "=== modinfo 8188eu ==="
    modinfo 8188eu 2>&1 || true

    echo "=== USB devices ==="
    for d in /sys/bus/usb/devices/*; do
      [ -e "$d" ] || continue
      echo "--- $d ---"
      for f in idVendor idProduct product manufacturer serial busnum devnum speed bDeviceClass bDeviceSubClass bDeviceProtocol; do
        [ -f "$d/$f" ] && echo "$f=$(cat "$d/$f")"
      done
      if [ -L "$d/driver" ]; then
        echo "driver=$(readlink "$d/driver")"
      fi
    done

    echo "=== MMC/SDIO devices ==="
    for d in /sys/bus/mmc/devices/*; do
      [ -e "$d" ] || continue
      echo "--- $d ---"
      find "$d" -maxdepth 1 -type f -print -exec cat {} \; 2>/dev/null
    done

    echo "=== network interfaces ==="
    ip addr 2>&1 || true

    echo "=== rfkill ==="
    rfkill list 2>&1 || true

    echo "=== iw dev ==="
    iw dev 2>&1 || true

    echo "=== debugfs gpio ==="
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
    cat /sys/kernel/debug/gpio 2>&1 || true

    echo "=== pinctrl gpio2/gpio3 ==="
    for f in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
      [ -f "$f" ] || continue
      echo "--- $f ---"
      grep -E 'gpio2|gpio3|GPIO2|GPIO3|73|115' "$f" 2>&1 || true
    done

    echo "=== regulators ==="
    cat /sys/kernel/debug/regulator/regulator_summary 2>&1 || true

    dump_lowlevel_usb_state "$label"
    dump_broad_register_state "$label"
    dump_pmic_i2c_state "$label"

    echo "=== dmesg filtered ==="
    dmesg | grep -iE 'usb|8188|rtl|wifi|wlan|firmware|phy|gpio|regulator|vcc|power|reset' 2>&1 || true
  } >> "$OUT" 2>&1
}

case "$1" in
  before)
    (
      snap early_before
      sleep 2
      snap before_2s
      sleep 8
      snap before_10s
      sleep 30
      snap before_40s
    ) &
    ;;
  after)
    (
      snap after
      sleep 10
      snap after_10s
    ) &
    ;;
  *)
    snap "manual_${1:-none}"
    ;;
esac

exit 0
