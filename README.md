# pi-ups-monitor

Headless Raspberry Pi image that watches a UPS and reports to [Healthchecks.io](https://healthchecks.io).

When wall power drops, Healthchecks gets an immediate `/fail` ping so you can fix wiring or untrip a breaker before the battery runs out. While everything is fine it heartbeats with UPS stats (charge, load, runtime).

Same provisioning pattern as the [Great Man Theory](https://github.com/djmango/great-man-theory) kiosk boards: SOPS-encrypted secrets, Wi-Fi + SSH key baked at build time, Tailscale enrollment on first boot.

## What you get

- Debian Bookworm image via `rpi-image-gen` (Docker on macOS)
- SSH key-only access, unique hostname per board
- Wi-Fi via NetworkManager + Tailscale
- `ups-monitor` timer that polls the UPS and pings Healthchecks
- Backends: **NUT** (`upsc`) or a generic **HTTP JSON** UPS API

## Healthchecks setup

Create two checks:

| Check | Purpose | How this repo uses it |
| --- | --- | --- |
| **Heartbeat** | Pi is alive | Success ping every poll with JSON log |
| **Mains** | Wall power present | Success on AC, `/fail` when on battery |

Point `HEALTHCHECKS_HEARTBEAT_URL` and `HEALTHCHECKS_MAINS_URL` at the ping URLs (full `https://hc-ping.com/<uuid>`).

Suggested periods: heartbeat period ≈ poll interval (60s), grace a few minutes. Mains period can be longer; the important part is the `/fail` on power loss.

## Secrets vs config

Non-secret settings live in plain `config.yaml` (backend, poll interval, device class, etc.).

Credentials and ping URLs live in SOPS-encrypted `secrets.yaml`:

```bash
bun run init-sops   # or: ./scripts/build-image.sh --init-sops
sops secrets.yaml
```

`secrets.yaml` and `.sops.yaml` are gitignored. Recipients are your **SSH ed25519 public key** (same pattern as GMT). SOPS labels that under the `age:` field — that is not a separate `age-keygen` key; it is still your SSH key. Decrypt uses `~/.ssh/id_ed25519` (override with `SOPS_AGE_SSH_PRIVATE_KEY_FILE`).

## Build & flash

```bash
bun run build
bun run flash -- --disk diskN --yes
```

Requires [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on macOS for verified flashes.

Device class defaults to `pi3` (Pi 3B / 3B+ rev 1.2). Override with `RPI_DEVICE_CLASS`: `pi3`, `pi4`, `pi5`, `cm4`, `cm5`, or `zero2w`.

## On the Pi

```bash
sudo ups-board-status
systemctl status ups-monitor.timer ups-monitor.service
journalctl -u ups-monitor.service -n 50
```

Logs also land on the boot partition (`/boot/firmware/ups-*.log`) so you can read them from macOS without booting the board.

## UPS backends

### NUT / APC USB (default)

Image includes `nut-server` + `usbhid-ups` preconfigured for a local APC USB UPS (e.g. Back-UPS ES). Set:

```yaml
UPS_BACKEND: nut
UPS_NUT_NAME: ups@localhost
```

### HTTP JSON API

If your UPS exposes an HTTP status endpoint:

```yaml
UPS_BACKEND: http
UPS_HTTP_URL: https://ups.local/api/status
UPS_HTTP_ON_BATTERY_PATH: status.onbattery   # dotted path; truthy = on battery
UPS_HTTP_BATTERY_PERCENT_PATH: battery.charge
UPS_HTTP_RUNTIME_SECONDS_PATH: battery.runtime
UPS_HTTP_LOAD_PERCENT_PATH: ups.load
```

Boolean-ish values accepted for on-battery: `true`/`false`, `1`/`0`, `yes`/`no`, `OB` (NUT-style).

## Recovery

```bash
./scripts/read-sd-logs.sh diskN
./scripts/inspect-sd.sh diskN
```

SSH over Tailscale after enrollment, then `sudo ups-board-status`.
