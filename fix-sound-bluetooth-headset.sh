#!/usr/bin/env bash
# Fix sound + Bluetooth on Apple T2 Macs (iMac / MacBook, Ubuntu, no sudo).
# Portable across the lab machines. One script, two problems:
#
#  1) SOUND DEAD: the T2 mic filter-chain confs in /etc/pipewire/pipewire.conf.d/
#     reference LADSPA plugins by bare name (amp_1181, sc4_1882, ...). PipeWire
#     resolves bare names via $LADSPA_PATH, which is empty, so the mandatory
#     filter-chain module fails -> pipewire exits 254 crash-loop -> wireplumber
#     (session manager) dies -> no sinks -> pactl "Connection refused".
#     Fix: point $LADSPA_PATH at the dir that holds the plugins.
#
#  2) BLUETOOTH CONNECT/DISCONNECT LOOP: the PipeWire Bluetooth backend package
#     libspa-0.2-bluetooth is not installed (wireplumber: "BlueZ SPA missing.
#     Bluetooth not supported"), so a headset connects but has no audio endpoint
#     and BlueZ tears the link down. The controller is often rfkill soft-blocked
#     too. Fix: fetch the matching .deb, extract into $HOME, expose it via a
#     private $SPA_PLUGIN_DIR, unblock rfkill.
#
# All user-level. No sudo. Persists across logout via ~/.config/environment.d/.

set -uo pipefail

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
CONF_DIR=/etc/pipewire/pipewire.conf.d
ENV_DIR="$HOME/.config/environment.d"
BT_PREFIX="$HOME/.local/pipewire-bt"
BT_MERGED="$HOME/.local/spa-0.2"
BT_PKG=libspa-0.2-bluetooth

say()  { printf '\n>> %s\n' "$*"; }
warn() { printf '   WARN: %s\n' "$*" >&2; }

mkdir -p "$ENV_DIR"

############################################################################
# PART 1 — SOUND: detect and set LADSPA_PATH
############################################################################
say "PART 1: sound (LADSPA_PATH)"

# plugins the confs need, bare names only (skip absolute-path refs)
NEEDED=()
while IFS= read -r line; do
    [ -n "$line" ] && NEEDED+=("$line")
done < <(
    grep -rhoE 'plugin *= *[A-Za-z0-9_.-]+' "$CONF_DIR" 2>/dev/null \
        | sed -E 's/.*= *//' | grep -vE '^/' | sort -u
)
[ "${#NEEDED[@]}" -eq 0 ] && say "No bare LADSPA plugins referenced (machine may be unaffected)."

LADSPA_DIRS=""   # colon-separated, deduped
add_ladspa() { case ":$LADSPA_DIRS:" in *":$1:"*) ;; *) LADSPA_DIRS="${LADSPA_DIRS:+$LADSPA_DIRS:}$1";; esac; }

LADSPA_CAND=(/usr/lib/ladspa /usr/lib/x86_64-linux-gnu/ladspa /usr/local/lib/ladspa /usr/lib64/ladspa "$HOME/.ladspa")
IFS=':' read -ra EX <<< "${LADSPA_PATH:-}"; LADSPA_CAND+=("${EX[@]}")

for d in "${LADSPA_CAND[@]}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    if [ "${#NEEDED[@]}" -eq 0 ]; then
        [ -n "$(ls -A "$d"/*.so 2>/dev/null)" ] && add_ladspa "$d"; continue
    fi
    for p in "${NEEDED[@]}"; do
        { [ -e "$d/$p.so" ] || [ -e "$d/$p" ]; } && add_ladspa "$d"
    done
done

if [ -n "$LADSPA_DIRS" ]; then
    say "LADSPA_PATH = $LADSPA_DIRS"
    printf 'LADSPA_PATH=%s\n' "$LADSPA_DIRS" > "$ENV_DIR/10-ladspa.conf"
    systemctl --user set-environment "LADSPA_PATH=$LADSPA_DIRS"
    OLD_IFS="$IFS"; IFS=':'
    for p in "${NEEDED[@]}"; do
        f=0; for d in $LADSPA_DIRS; do [ -e "$d/$p.so" ] && f=1; done
        [ "$f" -eq 0 ] && warn "'$p' not found anywhere; its filter-chain may still fail."
    done
    IFS="$OLD_IFS"
else
    [ "${#NEEDED[@]}" -gt 0 ] && warn "needed LADSPA plugins not found; may need: sudo apt install swh-plugins"
fi

############################################################################
# PART 2 — BLUETOOTH: provide PipeWire BlueZ SPA backend
############################################################################
say "PART 2: bluetooth (BlueZ SPA backend)"

SPA_STOCK="$(find /usr/lib -maxdepth 4 -type d -name 'spa-0.2' 2>/dev/null | head -1)"
if [ -z "$SPA_STOCK" ]; then
    warn "system spa-0.2 dir not found; skipping BT backend setup."
elif [ -e "$SPA_STOCK/bluez5/libspa-bluez5.so" ]; then
    say "BlueZ SPA already present system-wide; nothing to fetch."
else
    PW_VER="$(dpkg-query -W -f='${Version}' libpipewire-0.3-0 2>/dev/null || true)"
    say "Fetching $BT_PKG (pipewire ${PW_VER:-?}) — no sudo"
    WORK="$(mktemp -d)"
    ( cd "$WORK" && apt-get download "$BT_PKG" 2>&1 | tail -1 )
    DEB="$(ls "$WORK"/${BT_PKG}_*.deb 2>/dev/null | head -1)"
    if [ -z "$DEB" ]; then
        warn "could not download $BT_PKG; BT audio backend not installed."
        rm -rf "$WORK"
    else
        DEB_VER="$(dpkg-deb -f "$DEB" Version 2>/dev/null)"
        [ -n "$PW_VER" ] && [ "$DEB_VER" != "$PW_VER" ] && warn "bt plugin $DEB_VER != pipewire $PW_VER (possible ABI skew)."
        rm -rf "$BT_PREFIX"; mkdir -p "$BT_PREFIX"
        dpkg -x "$DEB" "$BT_PREFIX"; rm -rf "$WORK"
        BT_DIR="$(dirname "$(find "$BT_PREFIX" -name 'libspa-bluez5.so' 2>/dev/null | head -1)")"
        if [ -z "$BT_DIR" ] || [ ! -e "$BT_DIR/libspa-bluez5.so" ]; then
            warn "libspa-bluez5.so missing after extract."
        elif ldd "$BT_DIR/libspa-bluez5.so" 2>&1 | grep -q 'not found'; then
            warn "libspa-bluez5.so has unmet shared-lib deps (likely needs sudo):"
            ldd "$BT_DIR/libspa-bluez5.so" | grep 'not found' >&2
        else
            # merge stock SPA subdirs + new bluez5 into a private dir
            rm -rf "$BT_MERGED"; mkdir -p "$BT_MERGED"
            for sub in "$SPA_STOCK"/*/; do ln -sfn "${sub%/}" "$BT_MERGED/$(basename "$sub")"; done
            ln -sfn "$BT_DIR" "$BT_MERGED/bluez5"
            say "SPA_PLUGIN_DIR = $BT_MERGED"
            printf 'SPA_PLUGIN_DIR=%s\n' "$BT_MERGED" > "$ENV_DIR/20-spa-bt.conf"
            systemctl --user set-environment "SPA_PLUGIN_DIR=$BT_MERGED"
        fi
    fi
fi

############################################################################
# PART 3 — restart the audio stack
############################################################################
say "Restarting audio stack"
systemctl --user daemon-reexec 2>/dev/null || true
systemctl --user reset-failed pipewire.service pipewire.socket 2>/dev/null || true
systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null \
    || systemctl --user restart pipewire pipewire-pulse pipewire-media-session 2>/dev/null || true
for _ in $(seq 1 10); do
    systemctl --user is-active --quiet wireplumber 2>/dev/null && break
    sleep 1
done

############################################################################
# PART 4 — verify + reconnect bluetooth
############################################################################
say "Service state"
systemctl --user is-active pipewire wireplumber pipewire-pulse 2>/dev/null || true

if pactl info >/dev/null 2>&1; then
    say "Sinks:"; pactl list sinks short
    echo "Default sink: $(pactl get-default-sink 2>/dev/null || echo '?')"
    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true
else
    warn "pactl still refused. Debug: systemctl --user status pipewire ; systemctl --user show-environment | grep -E 'LADSPA|SPA'"
fi

if command -v bluetoothctl >/dev/null 2>&1; then
    say "Bluetooth: unblock + power on"
    rfkill unblock bluetooth 2>/dev/null || true          # clears soft-block, no sudo
    bluetoothctl power on >/dev/null 2>&1 || true
    bluetoothctl show 2>/dev/null | grep -E 'Powered' || true

    say "Paired devices:"
    PAIRED="$(bluetoothctl devices Paired 2>/dev/null)"
    [ -z "$PAIRED" ] && PAIRED="$(bluetoothctl devices 2>/dev/null)"
    echo "$PAIRED"

    # pick MAC dynamically: prefer already-connected device, else first paired
    MAC="$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2; exit}')"
    if [ -z "$MAC" ]; then
        MAC="$(echo "$PAIRED" | awk '{print $2; exit}')"
    fi

    if [ -n "$MAC" ]; then
        say "Using device MAC: $MAC"
        bluetoothctl connect "$MAC" >/dev/null 2>&1
        for _ in $(seq 1 10); do
            bluetoothctl info "$MAC" 2>/dev/null | grep -q 'Connected: yes' && break
            sleep 1
        done
        bluetoothctl info "$MAC" 2>/dev/null | grep -E 'Connected|Name'

        SINK_ID="$(echo "$MAC" | tr ':' '_')"
        sleep 1
        BLUE_SINK="$(pactl list sinks short 2>/dev/null | awk -v id="$SINK_ID" '$0 ~ id {print $2; exit}')"
        if [ -n "$BLUE_SINK" ]; then
            say "Bluetooth sink found: $BLUE_SINK"
            pactl set-default-sink "$BLUE_SINK" 2>/dev/null || true
            echo "Default sink now: $(pactl get-default-sink 2>/dev/null)"
        else
            warn "no bluez sink yet in pactl. Check: pactl list sinks short | grep -i blue"
        fi
    else
        warn "no paired device found. Pair first: bluetoothctl scan on ; bluetoothctl pair <MAC>"
    fi

    say "Test tone:  speaker-test -c2 -twav -l1"
fi

say "Done."
