#!/usr/bin/env bash
# Rollback for the Discord voice-ducking setup. See the discord-ducking repo, docs/DESIGN.md §8.
# Safe to run at any point, including before anything has been installed.
set -euo pipefail

# Stop EasyEffects, whether it runs under systemd or was launched manually.
#
# CRITICAL: `easyeffects --quit` does NOT exit when no instance is running --
# it LAUNCHES a fresh instance (window and all) and then blocks forever. Calling
# it unconditionally hangs the script. Only invoke it when an instance actually
# exists, cap it with `timeout` regardless, and fall back to `pkill -x`
# (exact process name -- never `pkill -f`, whose pattern can match this script).
stop_easyeffects() {
  systemctl --user stop easyeffects.service 2>/dev/null || true
  if pgrep -x easyeffects >/dev/null 2>&1; then
    timeout 10 easyeffects --quit >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -x easyeffects >/dev/null 2>&1 || break
      sleep 1
    done
  fi
  if pgrep -x easyeffects >/dev/null 2>&1; then
    pkill -x easyeffects 2>/dev/null || true
    sleep 1
  fi
}

echo "==> Removing PipeWire drop-ins"
rm -f ~/.config/pipewire/pipewire.conf.d/10-discord-sink.conf
rm -f ~/.config/pipewire/pipewire.conf.d/20-discord-loopback.conf
rm -f ~/.config/pipewire/pipewire-pulse.conf.d/50-discord-target.conf

echo "==> Removing EasyEffects user unit"
systemctl --user disable --now easyeffects.service 2>/dev/null || true
rm -f ~/.config/systemd/user/easyeffects.service
systemctl --user daemon-reload

# Stop any instance started outside systemd too: a stray one flushes its
# in-memory settings on exit and would silently undo the revert below.
stop_easyeffects

echo "==> Reverting EasyEffects settings (catch-all off, blocklist cleared)"
python3 - <<'PY' 2>/dev/null || true
import configparser, pathlib
p = pathlib.Path.home()/".config/easyeffects/db/easyeffectsrc"
if p.exists():
    c = configparser.ConfigParser(); c.optionxform=str; c.read(p)
    if c.has_section("StreamOutputs"):
        c.set("StreamOutputs","processAllOutputs","false")
        c.remove_option("StreamOutputs","blocklist")
        with p.open("w") as f: c.write(f, space_around_delimiters=False)
        print("   easyeffectsrc reverted")
PY

echo "==> Restarting audio stack"
systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 2
systemctl --user --no-pager --lines=0 status pipewire pipewire-pulse wireplumber || true

cat <<'MSG'

==> Automatic rollback complete. Two MANUAL steps remain:

  1. Discord -> Settings -> Voice & Video -> Output Device
     Set it back to your real output device. REQUIRED - it is otherwise
     pointing at a sink that no longer exists.

  2. EasyEffects "process all outputs" and the blocklist were reset automatically.
     To remove the packages entirely:
       sudo pacman -Rns easyeffects lsp-plugins-lv2

NOTE: ~/.local/state/wireplumber/stream-properties is deliberately NOT deleted.
It holds saved volume/routing for EVERY application on this system.
MSG
