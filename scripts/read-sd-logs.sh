#!/usr/bin/env bash
# Read UPS Pi state from SD card (read-only).
set -euo pipefail

export PAGER=cat
export LESS=FRX

disk="${1:-}"
if [ -z "$disk" ]; then
  echo "Usage: $0 diskN" >&2
  diskutil list external physical 2>/dev/null || true
  exit 1
fi

if ! command -v debugfs >/dev/null 2>&1; then
  exec nix shell nixpkgs#e2fsprogs -c "$0" "$@"
fi

redact_env() {
  sed -E 's/^(UPS_BOARD_WIFI_PASSWORD|TAILSCALE_AUTHKEY|HEALTHCHECKS_[A-Z_]+)=.*/\1=<redacted>/'
}

run() {
  local part="$1"
  local cmd="$2"
  sudo debugfs -R "$cmd" "$part" 2>/dev/null || true
}

root_part="/dev/${disk}s2"
boot_part="/dev/${disk}s1"

echo "=== SD layout for $disk ==="
diskutil list "$disk" 2>/dev/null || true
echo

if [ ! -e "$root_part" ]; then
  echo "Root partition not found at $root_part" >&2
  exit 1
fi

echo "=== root logs ==="
for path in \
  /var/log/ups-firstboot.log \
  /var/log/ups-tailscale.log \
  /var/log/ups-monitor.log \
  /var/lib/ups-board/firstboot.done \
  /var/lib/ups-board/tailscale.done \
  /var/lib/ups-board/last-mains-state; do
  echo "--- $path ---"
  run "$root_part" "cat $path"
  echo
done

echo "=== /etc/ups-board ==="
run "$root_part" 'cat /etc/ups-board/monitor.env' | redact_env
echo
run "$root_part" 'cat /etc/ups-board/provisioning.env' | redact_env
echo

mount_point=$(diskutil info "$boot_part" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')
if [ -n "$mount_point" ] && [ "$mount_point" != "Not mounted" ] && [ -d "$mount_point" ]; then
  echo "=== boot fat logs at $mount_point ==="
  for f in ups-firstboot.log ups-tailscale.log ups-monitor.log ups-board.env; do
    if [ -f "$mount_point/$f" ]; then
      echo "--- $f ---"
      redact_env < "$mount_point/$f" | tail -80
      echo
    fi
  done
else
  echo "Boot partition not mounted; insert/remount to read /boot/firmware/*.log from macOS."
fi
