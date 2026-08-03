#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-image.sh [options]

Build the pi-ups-monitor Raspberry Pi image with rpi-image-gen.

Options:
  --native       Run an existing local rpi-image-gen checkout instead of Docker.
  --no-prompt    Require values from env/secrets files and skip interactive prompts.
  --init-sops    Create encrypted secrets.yaml from the example template.
  -h, --help     Show this help.

Inputs, in precedence order:
  1. Environment variables
  2. secrets.yaml decrypted with sops
  3. Interactive prompts
EOF
}

native=0
no_prompt=0
init_sops=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --native) native=1 ;;
    --no-prompt) no_prompt=1 ;;
    --init-sops) init_sops=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

script_path="$(realpath "${BASH_SOURCE[0]}")"
script_dir="$(dirname -- "$script_path")"
repo_root="$(dirname "$script_dir")"
template_dir="$repo_root/image"
build_dir="$repo_root/build"
source_dir="$build_dir/source"
work_dir="$build_dir/work"
deploy_dir="$repo_root/deploy"
secrets_file="$repo_root/secrets.yaml"
sops_config="$repo_root/.sops.yaml"

mkdir -p "$build_dir" "$deploy_dir" "$work_dir"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

expand_path() {
  python3 -c 'import os, sys; print(os.path.expanduser(sys.argv[1]))' "$1"
}

write_sops_config() {
  local pubkey_path
  pubkey_path="$(expand_path "${1:-$HOME/.ssh/id_ed25519.pub}")"
  if [ ! -f "$pubkey_path" ]; then
    echo "SSH public key not found: $pubkey_path" >&2
    exit 1
  fi

  local pubkey
  pubkey="$(< "$pubkey_path")"
  cat > "$sops_config" <<EOF
creation_rules:
  - path_regex: secrets\\.yaml$
    age: $pubkey
EOF
}

if [ "$init_sops" -eq 1 ]; then
  require_command sops

  if [ -f "$secrets_file" ]; then
    echo "secrets.yaml already exists."
    echo "Edit it with: sops secrets.yaml"
    exit 0
  fi

  write_sops_config "${SSH_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
  cp "$repo_root/secrets.example.yaml" "$secrets_file"
  sops -e -i "$secrets_file"
  rm -f "$secrets_file.bak"

  cat <<EOF
Created .sops.yaml and encrypted secrets.yaml using your SSH public key.

Edit secrets with:
  sops secrets.yaml

Then build with:
  bun run build
EOF
  exit 0
fi

load_secrets() {
  if [ -f "$secrets_file" ]; then
    require_command sops
    require_command python3
    set -a
    # shellcheck disable=SC1090
    . <(sops -d --output-type json "$secrets_file" | python3 -c '
import json
import shlex
import sys

data = json.load(sys.stdin)
for key, value in data.items():
    if value is None:
        continue
    print(f"export {key}={shlex.quote(str(value))}")
')
    set +a
  fi
}

assign_var() {
  local name="$1"
  local value="$2"
  printf -v "$name" '%s' "$value"
  export "$name"
}

prompt_var() {
  local name="$1"
  local label="$2"
  local default_value="$3"
  local current_value="${!name:-}"
  local answer

  if [ -n "$current_value" ]; then
    return
  fi

  if [ "$no_prompt" -eq 1 ]; then
    assign_var "$name" "$default_value"
    return
  fi

  read -r -p "$label [$default_value]: " answer
  assign_var "$name" "${answer:-$default_value}"
}

prompt_secret() {
  local name="$1"
  local label="$2"
  local required="${3:-0}"
  local current_value="${!name:-}"
  local answer

  if [ -n "$current_value" ]; then
    return
  fi

  if [ "$no_prompt" -eq 1 ]; then
    if [ "$required" -eq 1 ]; then
      echo "$name is required when --no-prompt is used." >&2
      exit 1
    fi
    assign_var "$name" ""
    return
  fi

  read -r -s -p "$label: " answer
  printf '\n'
  if [ "$required" -eq 1 ] && [ -z "$answer" ]; then
    echo "$name is required." >&2
    exit 1
  fi
  assign_var "$name" "$answer"
}

load_secrets

if [ "$no_prompt" -eq 1 ] && [ ! -f "$secrets_file" ]; then
  echo "secrets.yaml is required when --no-prompt is used." >&2
  echo "Create one with: bun run init-sops" >&2
  exit 1
fi

prompt_var WIFI_COUNTRY "Wi-Fi country code" "US"
prompt_var WIFI_SSID "Wi-Fi SSID" "${WIFI_SSID:-}"
prompt_secret WIFI_PASSWORD "Wi-Fi password" 1
prompt_secret TAILSCALE_AUTH_KEY "Tailscale auth key (leave blank to skip)" 0
prompt_var HEALTHCHECKS_HEARTBEAT_URL "Healthchecks heartbeat ping URL" "${HEALTHCHECKS_HEARTBEAT_URL:-}"
prompt_var HEALTHCHECKS_MAINS_URL "Healthchecks mains ping URL" "${HEALTHCHECKS_MAINS_URL:-}"
prompt_var UPS_BACKEND "UPS backend (nut|http)" "nut"
prompt_var UPS_NUT_NAME "NUT UPS name" "ups@localhost"
prompt_var UPS_HTTP_URL "HTTP UPS status URL (if backend=http)" "${UPS_HTTP_URL:-}"
prompt_var UPS_POLL_INTERVAL_SECS "Poll interval seconds" "60"
prompt_var HOSTNAME_PREFIX "Hostname prefix" "skg-rpi-ups"
prompt_var RPI_DEVICE_CLASS "RPi device class (pi3, pi4, pi5, cm4, cm5, zero2w)" "pi3"
prompt_var RPI_USER "Linux username" "skg"
prompt_var RPI_IMAGE_NAME "Image name" "pi-ups-monitor"
prompt_var SSH_PUBKEY_PATH "SSH public key path" "$HOME/.ssh/id_ed25519.pub"

if [ -z "${WIFI_SSID:-}" ]; then
  echo "WIFI_SSID is required." >&2
  exit 1
fi

if [[ "${WIFI_SSID}" == REPLACE_ME* || "${WIFI_PASSWORD:-}" == REPLACE_ME* ]]; then
  echo "Replace the Wi-Fi placeholders in secrets.yaml before building." >&2
  echo "Edit with: sops secrets.yaml" >&2
  exit 1
fi

SSH_PUBKEY_PATH="$(expand_path "${SSH_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}")"

if [ ! -f "$SSH_PUBKEY_PATH" ]; then
  echo "SSH public key not found: $SSH_PUBKEY_PATH" >&2
  exit 1
fi
SSH_PUBKEY="$(< "$SSH_PUBKEY_PATH")"
export SSH_PUBKEY

TAILSCALE_UP_ARGS=${TAILSCALE_UP_ARGS:-"--accept-routes --accept-dns=false"}

if [[ "${TAILSCALE_AUTH_KEY:-}" == REPLACE_ME* ]]; then
  TAILSCALE_AUTH_KEY=""
fi
if [[ "${HEALTHCHECKS_HEARTBEAT_URL:-}" == *REPLACE_ME* ]]; then
  HEALTHCHECKS_HEARTBEAT_URL=""
fi
if [[ "${HEALTHCHECKS_MAINS_URL:-}" == *REPLACE_ME* ]]; then
  HEALTHCHECKS_MAINS_URL=""
fi

export TAILSCALE_UP_ARGS WIFI_SSID WIFI_PASSWORD WIFI_COUNTRY TAILSCALE_AUTH_KEY
export HEALTHCHECKS_HEARTBEAT_URL HEALTHCHECKS_MAINS_URL
export UPS_BACKEND UPS_NUT_NAME UPS_HTTP_URL UPS_POLL_INTERVAL_SECS HOSTNAME_PREFIX
export UPS_HTTP_ON_BATTERY_PATH="${UPS_HTTP_ON_BATTERY_PATH:-on_battery}"
export UPS_HTTP_BATTERY_PERCENT_PATH="${UPS_HTTP_BATTERY_PERCENT_PATH:-battery.charge}"
export UPS_HTTP_RUNTIME_SECONDS_PATH="${UPS_HTTP_RUNTIME_SECONDS_PATH:-battery.runtime}"
export UPS_HTTP_LOAD_PERCENT_PATH="${UPS_HTTP_LOAD_PERCENT_PATH:-ups.load}"
export UPS_HTTP_HEADERS="${UPS_HTTP_HEADERS:-}"

require_command rsync

rm -rf "$source_dir"
mkdir -p "$source_dir"
rsync -a --delete "$template_dir"/ "$source_dir"/

ssh_dir="$source_dir/rootfs-overlay/home/$RPI_USER/.ssh"
install -d -m 0700 "$ssh_dir"
printf '%s\n' "$SSH_PUBKEY" > "$ssh_dir/authorized_keys"
chmod 0600 "$ssh_dir/authorized_keys"

build_args=(
  "IGconf_sys_workroot=/work"
  "IGconf_device_class=$RPI_DEVICE_CLASS"
  "IGconf_device_user1=$RPI_USER"
  "IGconf_image_name=$RPI_IMAGE_NAME"
  "IGconf_ssh_pubkey_user1=$SSH_PUBKEY"
  IGconf_ssh_pubkey_only=y
  "IGconf_ups_backend=$UPS_BACKEND"
  "IGconf_ups_nut_name=$UPS_NUT_NAME"
  "IGconf_ups_http_url=${UPS_HTTP_URL:-}"
  "IGconf_ups_http_on_battery_path=$UPS_HTTP_ON_BATTERY_PATH"
  "IGconf_ups_http_battery_percent_path=$UPS_HTTP_BATTERY_PERCENT_PATH"
  "IGconf_ups_http_runtime_seconds_path=$UPS_HTTP_RUNTIME_SECONDS_PATH"
  "IGconf_ups_http_load_percent_path=$UPS_HTTP_LOAD_PERCENT_PATH"
  "IGconf_ups_http_headers=$UPS_HTTP_HEADERS"
  "IGconf_ups_healthchecks_heartbeat_url=${HEALTHCHECKS_HEARTBEAT_URL:-}"
  "IGconf_ups_healthchecks_mains_url=${HEALTHCHECKS_MAINS_URL:-}"
  "IGconf_ups_poll_interval_secs=$UPS_POLL_INTERVAL_SECS"
  "IGconf_ups_hostname_prefix=$HOSTNAME_PREFIX"
)

if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
  build_args+=("IGconf_ups_tailscale_authkey=$TAILSCALE_AUTH_KEY")
  build_args+=("IGconf_ups_tailscale_up_args=$TAILSCALE_UP_ARGS")
fi

if [ -n "${WIFI_SSID:-}" ]; then
  build_args+=("IGconf_ups_wifi_ssid=$WIFI_SSID")
  build_args+=("IGconf_ups_wifi_password=${WIFI_PASSWORD:-}")
  build_args+=("IGconf_ups_wifi_country=${WIFI_COUNTRY:-US}")
fi

copy_artifacts() {
  local work_root="$1"
  for dir in "$work_root"/deploy-* "$work_root"/image-*; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
      if ! cp -a "$file" "$deploy_dir"/; then
        case "$file" in
          *.img)
            echo "warning: skipped copying raw image $(basename "$file") to macOS deploy mount" >&2
            ;;
          *)
            echo "failed to copy $(basename "$file")" >&2
            return 1
            ;;
        esac
      fi
    done < <(find "$dir" -maxdepth 1 -type f \( \
      -name "${RPI_IMAGE_NAME}*" \
      -o -name "image.json" \
      -o -name "manifest" \
      -o -name "config.yaml" \
      -o -name "kernel_*.img" \
      -o -name "boot.vfat" \
      -o -name "root.ext4" \
      \) -print0)
  done
}

copy_raw_image=0
if [ "$(uname -s)" != "Darwin" ]; then
  copy_raw_image=1
fi

run_build_cmd='
set -euo pipefail
args=(
  IGconf_sys_workroot=/work
  "IGconf_device_class=$RPI_DEVICE_CLASS"
  "IGconf_device_user1=$RPI_USER"
  "IGconf_image_name=$RPI_IMAGE_NAME"
  "IGconf_ssh_pubkey_user1=$SSH_PUBKEY"
  IGconf_ssh_pubkey_only=y
  "IGconf_ups_backend=$UPS_BACKEND"
  "IGconf_ups_nut_name=$UPS_NUT_NAME"
  "IGconf_ups_http_url=${UPS_HTTP_URL:-}"
  "IGconf_ups_http_on_battery_path=$UPS_HTTP_ON_BATTERY_PATH"
  "IGconf_ups_http_battery_percent_path=$UPS_HTTP_BATTERY_PERCENT_PATH"
  "IGconf_ups_http_runtime_seconds_path=$UPS_HTTP_RUNTIME_SECONDS_PATH"
  "IGconf_ups_http_load_percent_path=$UPS_HTTP_LOAD_PERCENT_PATH"
  "IGconf_ups_http_headers=$UPS_HTTP_HEADERS"
  "IGconf_ups_healthchecks_heartbeat_url=${HEALTHCHECKS_HEARTBEAT_URL:-}"
  "IGconf_ups_healthchecks_mains_url=${HEALTHCHECKS_MAINS_URL:-}"
  "IGconf_ups_poll_interval_secs=$UPS_POLL_INTERVAL_SECS"
  "IGconf_ups_hostname_prefix=$HOSTNAME_PREFIX"
)
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
  args+=("IGconf_ups_tailscale_authkey=$TAILSCALE_AUTH_KEY")
  args+=("IGconf_ups_tailscale_up_args=$TAILSCALE_UP_ARGS")
fi
if [ -n "${WIFI_SSID:-}" ]; then
  args+=("IGconf_ups_wifi_ssid=$WIFI_SSID")
  args+=("IGconf_ups_wifi_password=${WIFI_PASSWORD:-}")
  args+=("IGconf_ups_wifi_country=${WIFI_COUNTRY:-US}")
fi
/opt/rpi-image-gen/rpi-image-gen build -S /src -c ups-monitor.yaml -- "${args[@]}"

IMAGE_DIR=""
for dir in /work/image-*; do
  [ -d "$dir" ] || continue
  [ -f "$dir/${RPI_IMAGE_NAME}.img" ] || continue
  IMAGE_DIR="$dir"
  break
done

if [ -z "$IMAGE_DIR" ]; then
  echo "build-image.sh: no image output directory found under /work/image-*" >&2
  exit 1
fi

echo "Patching generated image boot args in $IMAGE_DIR"
bash /scripts/patch-image-inner.sh "$IMAGE_DIR" "$RPI_IMAGE_NAME" "$RPI_USER"

mkdir -p /deploy
shopt -s nullglob

copy_if_newer() {
  local src=$1
  local dest=/deploy/$(basename "$src")
  if [ ! -e "$dest" ] || [ "$src" -nt "$dest" ]; then
    cp -a "$src" "$dest"
  fi
}

for file in \
  "$IMAGE_DIR/${RPI_IMAGE_NAME}.img.zst" \
  "$IMAGE_DIR/image.json" \
  "$IMAGE_DIR/manifest" \
  "$IMAGE_DIR/config.yaml" \
  "$IMAGE_DIR/kernel_"*.img; do
  [ -e "$file" ] || continue
  copy_if_newer "$file"
done

for dir in /work/deploy-*; do
  [ -d "$dir" ] || continue
  for file in "$dir"/manifest "$dir"/config.yaml "$dir"/image.json "$dir"/*.sbom "$dir"/*.tar.zst; do
    [ -e "$file" ] || continue
    copy_if_newer "$file"
  done
done

if [ "${COPY_RAW_IMAGE:-0}" = "1" ]; then
  copy_if_newer "$IMAGE_DIR/${RPI_IMAGE_NAME}.img" || true
fi

sha256sum "$IMAGE_DIR/${RPI_IMAGE_NAME}.img" | awk "{print \$1}" > "/deploy/${RPI_IMAGE_NAME}.img.sha256"
'

if [ "$native" -eq 1 ]; then
  rpi_image_gen="${RPI_IMAGE_GEN_DIR:-$build_dir/rpi-image-gen}"
  if [ ! -x "$rpi_image_gen/rpi-image-gen" ]; then
    echo "Native mode requires RPI_IMAGE_GEN_DIR to point at an installed rpi-image-gen checkout." >&2
    echo "Docker mode is the default and will build the checkout into a container." >&2
    exit 1
  fi

  native_build_args=("${build_args[@]}")
  native_build_args[0]="IGconf_sys_workroot=$work_dir"
  "$rpi_image_gen/rpi-image-gen" build -S "$source_dir" -c ups-monitor.yaml -- "${native_build_args[@]}"
  for dir in "$work_dir"/image-*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/${RPI_IMAGE_NAME}.img" ]; then
      "$script_dir/patch-image-inner.sh" "$dir" "$RPI_IMAGE_NAME" "$RPI_USER"
    fi
  done
  copy_artifacts "$work_dir"
  if [ -f "$work_dir/image-${RPI_IMAGE_NAME}/${RPI_IMAGE_NAME}.img" ]; then
    shasum -a 256 "$work_dir/image-${RPI_IMAGE_NAME}/${RPI_IMAGE_NAME}.img" \
      | awk '{print $1}' > "$deploy_dir/${RPI_IMAGE_NAME}.img.sha256"
  fi
else
  require_command docker

  docker_image="${DOCKER_IMAGE:-pi-ups-monitor-rpi-image-gen}"
  docker_platform="${DOCKER_PLATFORM:-linux/arm64}"
  work_volume="${DOCKER_WORK_VOLUME:-pi-ups-monitor-rpi-work}"

  docker build --platform "$docker_platform" -t "$docker_image" "$repo_root"
  docker volume inspect "$work_volume" >/dev/null 2>&1 || docker volume create "$work_volume" >/dev/null

  docker run --rm \
    --privileged \
    --userns=host \
    --security-opt seccomp=unconfined \
    --platform "$docker_platform" \
    -v /dev:/dev \
    -v "$work_volume:/work" \
    -e RPI_DEVICE_CLASS \
    -e RPI_USER \
    -e RPI_IMAGE_NAME \
    -e TAILSCALE_AUTH_KEY \
    -e TAILSCALE_UP_ARGS \
    -e WIFI_SSID \
    -e WIFI_PASSWORD \
    -e WIFI_COUNTRY \
    -e SSH_PUBKEY \
    -e UPS_BACKEND \
    -e UPS_NUT_NAME \
    -e UPS_HTTP_URL \
    -e UPS_HTTP_ON_BATTERY_PATH \
    -e UPS_HTTP_BATTERY_PERCENT_PATH \
    -e UPS_HTTP_RUNTIME_SECONDS_PATH \
    -e UPS_HTTP_LOAD_PERCENT_PATH \
    -e UPS_HTTP_HEADERS \
    -e HEALTHCHECKS_HEARTBEAT_URL \
    -e HEALTHCHECKS_MAINS_URL \
    -e UPS_POLL_INTERVAL_SECS \
    -e HOSTNAME_PREFIX \
    -e COPY_RAW_IMAGE="$copy_raw_image" \
    -v "$source_dir:/src:ro" \
    -v "$script_dir:/scripts:ro" \
    -v "$deploy_dir:/deploy" \
    "$docker_image" \
    bash -lc "$run_build_cmd"
fi

echo "Build artefacts copied to $deploy_dir"
if [ -f "$deploy_dir/${RPI_IMAGE_NAME}.img.sha256" ]; then
  echo "SHA256: $(tr -d '[:space:]' < "$deploy_dir/${RPI_IMAGE_NAME}.img.sha256")"
fi
