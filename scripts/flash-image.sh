#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/flash-image.sh [--image path] [--disk diskN] [--yes] [--no-verify]

Flash the latest image from deploy/ to an SD card or USB drive on macOS.

Verification is ON by default. Raspberry Pi Imager writes the image, then reads
the card back to confirm the write. Progress may sit at 100% for several minutes
during that verify pass — that is normal.

Requires Raspberry Pi Imager.app for verified flashes.

Options:
  --no-verify   Skip the post-write verify pass (not recommended)

Examples:
  scripts/flash-image.sh --disk disk18
  bun run flash -- --disk disk18 --yes
EOF
}

image=""
disk=""
assume_yes=0
skip_verify=0
RPI_IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      image="${2:-}"
      shift
      ;;
    --disk)
      disk="${2:-}"
      shift
      ;;
    -y|--yes)
      assume_yes=1
      ;;
    --no-verify)
      skip_verify=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

script_path="$(realpath "${BASH_SOURCE[0]}")"
script_dir="$(dirname -- "$script_path")"
repo_root="$(dirname "$script_dir")"
deploy_dir="$repo_root/deploy"

pick_newest() {
  local newest=""
  local candidate
  for candidate in "$@"; do
    [ -f "$candidate" ] || continue
    if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
      newest="$candidate"
    fi
  done
  printf '%s' "$newest"
}

image_bytes() {
  local file=$1
  case "$file" in
    *.zst)
      zstd -lv "$file" 2>/dev/null | awk -F '[()]' '/Decompressed Size:/ {gsub(/[^0-9]/, "", $2); print $2; exit}'
      ;;
    *.xz)
      xz -l -v "$file" 2>/dev/null | awk '/Uncompressed size/ {print $NF; exit}'
      ;;
    *.img)
      wc -c < "$file" | tr -d ' '
      ;;
    *)
      return 1
      ;;
  esac
}

human_size() {
  local bytes=$1
  awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB", u, " ")
    i=1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

if [ -z "$image" ]; then
  shopt -s nullglob
  preferred=(
    "$deploy_dir"/pi-ups-monitor.img.zst
    "$deploy_dir"/pi-ups-monitor.img.xz
    "$deploy_dir"/pi-ups-monitor.img
  )
  others=()
  for candidate in \
    "$deploy_dir"/*.img.zst \
    "$deploy_dir"/*.img.xz \
    "$deploy_dir"/*.img; do
    [ -f "$candidate" ] || continue
    case "$(basename "$candidate")" in
      kernel_*.img|*.sparse|*.sparse.*|*.tar.zst) continue ;;
    esac
    others+=("$candidate")
  done
  shopt -u nullglob

  image="$(pick_newest "${preferred[@]}")"
  if [ -z "$image" ]; then
    image="$(pick_newest "${others[@]}")"
  fi
fi

if [ -z "$image" ] || [ ! -f "$image" ]; then
  echo "No image found. Build one first with: bun run build" >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This flash helper currently supports macOS diskutil only." >&2
  exit 1
fi

if [ -z "$disk" ]; then
  external_disks=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    external_disks+=("$line")
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ \(external/ {gsub(/^\/dev\//,""); print}')

  if [ "${#external_disks[@]}" -eq 1 ]; then
    disk="${external_disks[0]}"
    echo "Using sole external disk: $disk"
  else
    diskutil list external physical
    read -r -p "Target disk identifier (e.g. disk18, not 0 or s1): " disk
  fi
fi

disk="${disk#/dev/}"
if [[ "$disk" =~ ^(disk[0-9]+)s[0-9]+$ ]]; then
  echo "Use the whole disk (${BASH_REMATCH[1]}), not a partition ($disk)." >&2
  exit 1
fi

if ! [[ "$disk" =~ ^disk[0-9]+$ ]]; then
  echo "Refusing to flash invalid disk identifier: $disk" >&2
  exit 1
fi

device="/dev/$disk"
raw_device="/dev/r$disk"

if ! diskutil info "$device" >/dev/null 2>&1; then
  echo "Disk does not exist: $device" >&2
  exit 1
fi

bytes="$(image_bytes "$image" || true)"
if [ -n "$bytes" ]; then
  echo "Image: $image ($(human_size "$bytes") written to card)"
else
  echo "Image: $image"
fi
diskutil info "$device" | sed -n 's/^   Device \/ Media Name: */Disk: /p; s/^   Disk Size: */Size: /p; s/^   Removable Media: */Removable: /p'
echo
if [ "$skip_verify" -eq 0 ]; then
  echo "Verify: enabled (Imager will read the card back after writing)."
  hash_file="${image%.zst}"
  hash_file="${hash_file%.xz}.sha256"
  if [ -f "$hash_file" ]; then
    echo "SHA256: $(tr -d '[:space:]' < "$hash_file")"
  else
    echo "SHA256 sidecar missing; Imager will still verify the card readback."
    echo "Rebuild with bun run build to generate deploy/*.img.sha256"
  fi
fi
echo

if [ "$assume_yes" -eq 0 ]; then
  read -r -p "Type FLASH to erase and write $device: " confirmation
  if [ "$confirmation" != "FLASH" ]; then
    echo "Aborted."
    exit 1
  fi
fi

diskutil unmountDisk "$device"

flash_with_imager() {
  local -a args=(--cli)
  local hash_file="${image%.zst}"
  hash_file="${hash_file%.xz}.sha256"
  local expected_hash=""

  if [ "$skip_verify" -eq 1 ]; then
    args+=(--disable-verify)
  fi
  if [ -f "$hash_file" ]; then
    expected_hash="$(tr -d '[:space:]' < "$hash_file")"
    if [ -n "$expected_hash" ]; then
      args+=(--sha256 "$expected_hash")
    fi
  fi

  args+=("$image" "$device")
  "$RPI_IMAGER" "${args[@]}"
}

flash_with_dd() {
  local count=""
  if [ -n "$bytes" ]; then
    count=$(( (bytes + 1048575) / 1048576 ))
  fi

  case "$image" in
    *.img)
      if [ -n "$count" ]; then
        sudo dd if="$image" of="$raw_device" bs=1m count="$count" status=progress
      else
        sudo dd if="$image" of="$raw_device" bs=1m status=progress
      fi
      ;;
    *.img.xz)
      command -v xzcat >/dev/null 2>&1 || { echo "xzcat is required for .xz images." >&2; exit 1; }
      if [ -n "$count" ]; then
        xzcat "$image" | sudo dd of="$raw_device" bs=1m count="$count" status=progress
      else
        xzcat "$image" | sudo dd of="$raw_device" bs=1m status=progress
      fi
      ;;
    *.img.zst)
      command -v zstdcat >/dev/null 2>&1 || { echo "zstdcat is required for .zst images." >&2; exit 1; }
      if [ -n "$count" ]; then
        zstdcat "$image" | sudo dd of="$raw_device" bs=1m count="$count" status=progress
      else
        zstdcat "$image" | sudo dd of="$raw_device" bs=1m status=progress
      fi
      ;;
    *)
      echo "Unsupported image extension: $image" >&2
      exit 1
      ;;
  esac
}

if [ "$skip_verify" -eq 0 ] && [ ! -x "$RPI_IMAGER" ]; then
  echo "Verified flashing requires Raspberry Pi Imager.app." >&2
  echo "Install from https://www.raspberrypi.com/software/ or pass --no-verify to use dd." >&2
  exit 1
fi

if [ -x "$RPI_IMAGER" ]; then
  if [ "$skip_verify" -eq 1 ]; then
    echo "Writing with Raspberry Pi Imager CLI (verify disabled)..."
  else
    echo "Writing with Raspberry Pi Imager CLI (verify enabled)..."
    echo "Step 1/2: write image to card."
    echo "Step 2/2: verify by reading the card back. Progress may stay at 100% for several minutes."
  fi
  flash_with_imager
  if [ "$skip_verify" -eq 0 ]; then
    echo "Verify passed."
  fi
else
  echo "Raspberry Pi Imager not found; falling back to dd without verification."
  flash_with_dd
fi

sync

eject_disk() {
  if diskutil eject "$device" 2>/dev/null; then
    return 0
  fi

  diskutil unmountDisk force "$device" >/dev/null 2>&1 || true
  if diskutil eject "$device" 2>/dev/null; then
    return 0
  fi

  return 1
}

if eject_disk; then
  echo "Flashed and ejected $device."
else
  echo "Flash completed successfully, but macOS would not eject $device (Spotlight sometimes remounts the card)." >&2
  echo "Safely remove it with: diskutil unmountDisk force $device && diskutil eject $device" >&2
  echo "Or unplug the card now — the image is already written." >&2
fi
