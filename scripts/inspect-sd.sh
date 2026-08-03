#!/usr/bin/env bash
# Read-only SD card inspection via debugfs (no writes).
set -euo pipefail

disk="${1:-}"
if [ -z "$disk" ]; then
  echo "Usage: $0 diskN   (e.g. disk18 — uses /dev/diskN s2 root partition)" >&2
  diskutil list external physical 2>/dev/null || diskutil list external 2>/dev/null || true
  exit 1
fi

part="/dev/${disk}s2"
boot_part="/dev/${disk}s1"
if [ ! -e "$part" ]; then
  part="/dev/$disk"
fi

if ! command -v debugfs >/dev/null 2>&1; then
  exec nix shell nixpkgs#e2fsprogs -c "$0" "$@"
fi

run() {
  sudo debugfs -R "$1" "$part" 2>/dev/null || true
}

redact_env() {
  sed -E 's/^(UPS_BOARD_WIFI_PASSWORD|TAILSCALE_AUTHKEY|HEALTHCHECKS_[A-Z_]+)=.*/\1=<redacted>/'
}

echo "=== $part (root) ==="
echo

echo "=== /etc/os-release ==="
run 'cat /etc/os-release'
echo

echo "=== /etc/hostname ==="
run 'cat /etc/hostname'
echo

echo "=== /etc/ups-board/monitor.env ==="
run 'cat /etc/ups-board/monitor.env' | redact_env
echo

echo "=== /etc/ups-board/provisioning.env ==="
run 'cat /etc/ups-board/provisioning.env' | redact_env
echo

echo "=== systemd wants ==="
run 'ls -l /etc/systemd/system/multi-user.target.wants'
run 'ls -l /etc/systemd/system/timers.target.wants'
echo

if [ -e "$boot_part" ]; then
  echo "=== boot partition $boot_part (mount if needed for fat logs) ==="
  diskutil info "$boot_part" 2>/dev/null | sed -n 's/^   Volume Name: */Volume: /p; s/^   Mount Point: */Mount: /p' || true
fi
