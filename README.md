# fix-sound-bt.sh

Fixes sound and Bluetooth on Apple T2 Macs (iMac / MacBook) running Ubuntu, lab machines, no sudo required.

## Problems it fixes

### 1. Sound dead
T2 mic filter-chain configs in `/etc/pipewire/pipewire.conf.d/` reference LADSPA plugins by bare name (`amp_1181`, `sc4_1882`, ...). PipeWire resolves bare names via `$LADSPA_PATH`, which is empty by default, so the mandatory filter-chain module fails, PipeWire crash-loops (exit 254), wireplumber dies, and `pactl` returns "Connection refused".

**Fix:** detect where the needed plugins live and export `LADSPA_PATH` pointing to that directory.

### 2. Bluetooth connect/disconnect loop
The PipeWire Bluetooth backend package `libspa-0.2-bluetooth` is missing, so wireplumber logs "BlueZ SPA missing. Bluetooth not supported." A headset connects but gets no audio endpoint, so BlueZ tears the link back down. The controller is often also rfkill soft-blocked.

**Fix:** download the matching `.deb` with `apt-get download` (no sudo needed for download), extract it into `$HOME`, expose it through a private `$SPA_PLUGIN_DIR`, and unblock rfkill.

## What it does, step by step

1. **Sound**
   - Scans `pipewire.conf.d` for bare LADSPA plugin names.
   - Searches common LADSPA directories (system + `$HOME/.ladspa`) for those plugins.
   - Writes `LADSPA_PATH` to `~/.config/environment.d/10-ladspa.conf` and applies it live via `systemctl --user set-environment`.
2. **Bluetooth**
   - Checks if `libspa-bluez5.so` already exists system-wide.
   - If not, downloads `libspa-0.2-bluetooth` matching the installed PipeWire version, extracts it under `$HOME`, and symlinks it alongside the stock SPA plugin directories into a private `SPA_PLUGIN_DIR`.
   - Warns if there's a version mismatch or missing shared-library dependencies (those usually need sudo to resolve).
3. **Restart audio stack**
   - Resets failed units, restarts `pipewire`, `pipewire-pulse`, and `wireplumber` (falls back to `pipewire-media-session` on older setups).
4. **Verify + reconnect Bluetooth**
   - Confirms services are active and lists sinks.
   - Unblocks rfkill and powers on the Bluetooth adapter.
   - **Auto-detects the device MAC** — no manual copy/paste:
     - Prefers a device already marked `Connected`.
     - Otherwise falls back to the first `Paired` device.
   - Connects to that MAC, waits up to 10s for confirmation.
   - Finds the matching PipeWire sink automatically and sets it as default.
   - Runs a test tone suggestion at the end.

## Usage

```bash
chmod +x fix-sound-bt.sh
./fix-sound-bt.sh
```

No sudo needed. Safe to re-run any time (idempotent — re-detects state each run).

## Requirements

- At least one Bluetooth device already **paired** (script connects, it doesn't pair). If none are paired yet:
  ```bash
  bluetoothctl scan on
  bluetoothctl pair <MAC>
  ```
- `apt-get download` must be able to reach your configured package mirrors (needed for the Bluetooth backend fetch only; skipped if already installed system-wide).

## Troubleshooting

| Symptom | Likely cause | What to check |
|---|---|---|
| `WARN: needed LADSPA plugins not found` | `swh-plugins` not installed | `sudo apt install swh-plugins` |
| `WARN: bt plugin X != pipewire Y (possible ABI skew)` | Downloaded backend version mismatch | Usually still works; if not, needs a matching sudo-installed package |
| `WARN: libspa-bluez5.so has unmet shared-lib deps` | Missing system libraries | Needs sudo to install the listed deps |
| `pactl` still refuses after run | Environment not picked up by session | `systemctl --user show-environment \| grep -E 'LADSPA\|SPA'`, then log out/in |
| No device found for auto-connect | Nothing paired yet | Pair first (see Requirements above) |
| Connected but no sink appears | PipeWire hasn't registered the sink yet | Wait a few seconds, then `pactl list sinks short \| grep -i blue` |

## Design notes

- Everything is user-level (`$HOME`, `systemd --user`, `environment.d`) so no sudo is required for the common case, and settings persist across logout/login.
- Bluetooth backend files live in a private prefix (`~/.local/pipewire-bt`, merged into `~/.local/spa-0.2`) rather than overwriting anything system-wide.
- MAC address selection is dynamic: the script reads `bluetoothctl devices Connected` / `bluetoothctl devices Paired` at runtime rather than requiring a hardcoded address, so the same script works unmodified across different machines and different headsets.
