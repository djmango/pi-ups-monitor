#!/usr/bin/env bash
# Patch rpi-image-gen SD-card artifacts to boot by filesystem label.
# Runs natively on Linux (inside the build container or on a Debian host).

set -euo pipefail

DIST_DIR=${1:-}
IMAGE_NAME=${2:-pi-ups-monitor}
RPI_USER=${3:-skg}

if [ -z "$DIST_DIR" ]; then
  echo "usage: $0 <artifact-dir> [image-name] [username]" >&2
  exit 1
fi
DIST_DIR=$(cd "$DIST_DIR" && pwd)

IMG="$DIST_DIR/${IMAGE_NAME}.img"
if [ ! -f "$IMG" ]; then
  echo "patch-image-inner.sh: missing $IMG" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "patch-image-inner.sh: missing command: $1" >&2
    exit 1
  fi
}

require_cmd fdisk
require_cmd mcopy
require_cmd mtype
require_cmd debugfs
require_cmd dd

patch_boot() {
  local image=$1
  local offset_arg=${2:-}
  local tmp
  tmp=$(mktemp -d)
  mcopy -i "${image}${offset_arg}" ::cmdline.txt "$tmp/cmdline.txt"
  sed -i 's|root=[^ ]*|root=LABEL=ROOT|g' "$tmp/cmdline.txt"
  grep -q 'rootfstype=ext4' "$tmp/cmdline.txt" || sed -i 's|$| rootfstype=ext4|' "$tmp/cmdline.txt"
  grep -q 'rootwait' "$tmp/cmdline.txt" || sed -i 's|$| rootwait|' "$tmp/cmdline.txt"
  mcopy -o -i "${image}${offset_arg}" "$tmp/cmdline.txt" ::cmdline.txt
  rm -rf "$tmp"
}

patch_fstab_ext4() {
  local image=$1
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/fstab" <<'FSTAB'
LABEL=ROOT / ext4 rw,relatime,errors=remount-ro,commit=30 0 1
LABEL=BOOT /boot/firmware vfat defaults,rw,noatime,errors=remount-ro 0 2
FSTAB
  debugfs -w -R 'rm /etc/fstab' "$image" >/dev/null 2>&1 || true
  debugfs -w -R "write $tmp/fstab /etc/fstab" "$image" >/dev/null
  rm -rf "$tmp"
}

# The rootfs-overlay copy leaves ~/.ssh root-owned, which makes sshd
# reject pubkey auth. Force correct ownership on the final ext4 artifacts.
patch_ssh_ownership() {
  local image=$1
  local path
  for path in "/home/$RPI_USER" "/home/$RPI_USER/.ssh" "/home/$RPI_USER/.ssh/authorized_keys"; do
    debugfs -w -R "sif $path uid 1000" "$image" >/dev/null 2>&1 || true
    debugfs -w -R "sif $path gid 1000" "$image" >/dev/null 2>&1 || true
  done
}

read_partition_layout() {
  local img=$1
  local boot_marker="${IMAGE_NAME}.img1"
  local root_marker="${IMAGE_NAME}.img2"

  if command -v partx >/dev/null 2>&1; then
    BOOT_START=$(partx -s -o START -g -n 1 "$img")
    ROOT_START=$(partx -s -o START -g -n 2 "$img")
    ROOT_SECTORS=$(partx -s -o SECTORS -g -n 2 "$img")
    if [ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] && [ -n "$ROOT_SECTORS" ]; then
      return 0
    fi
  fi

  BOOT_START=$(fdisk -l "$img" | awk -v pat="$boot_marker" '$0 ~ pat {print ($2 == "*" ? $3 : $2); exit}')
  ROOT_START=$(fdisk -l "$img" | awk -v pat="$root_marker" '$0 ~ pat {print ($2 == "*" ? $3 : $2); exit}')
  ROOT_SECTORS=$(fdisk -l "$img" | awk -v pat="$root_marker" '$0 ~ pat {print ($2 == "*" ? $5 : $4); exit}')
}

read_partition_layout "$IMG"

if [ -z "${BOOT_START:-}" ] || [ -z "${ROOT_START:-}" ] || [ -z "${ROOT_SECTORS:-}" ]; then
  echo "patch-image-inner.sh: unable to parse partition table for $IMG" >&2
  fdisk -l "$IMG" >&2 || true
  exit 1
fi

BOOT_OFFSET=$((BOOT_START * 512))

if [ -f "$DIST_DIR/boot.vfat" ]; then
  patch_boot "$DIST_DIR/boot.vfat"
fi
if [ -f "$DIST_DIR/root.ext4" ]; then
  patch_fstab_ext4 "$DIST_DIR/root.ext4"
  patch_ssh_ownership "$DIST_DIR/root.ext4"
fi

patch_boot "$IMG" "@@${BOOT_OFFSET}"
dd if="$IMG" of=/tmp/ups-root.ext4 bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" status=none
patch_fstab_ext4 /tmp/ups-root.ext4
patch_ssh_ownership /tmp/ups-root.ext4
dd if=/tmp/ups-root.ext4 of="$IMG" bs=512 seek="$ROOT_START" conv=notrunc status=none
sync

if command -v zstd >/dev/null 2>&1; then
  zstd -f -q "$IMG" -o "$DIST_DIR/${IMAGE_NAME}.img.zst"
fi

echo "patched boot cmdline:"
mtype -i "${IMG}@@${BOOT_OFFSET}" ::cmdline.txt
echo "patched root fstab:"
debugfs -R 'cat /etc/fstab' /tmp/ups-root.ext4 2>/dev/null
echo "ssh dir ownership:"
debugfs -R "stat /home/$RPI_USER/.ssh/authorized_keys" /tmp/ups-root.ext4 2>/dev/null | grep -E 'User|Mode'
