#!/usr/bin/env bash
# Rollback for the Discord voice-ducking setup. See the discord-ducking repo, docs/DESIGN.md §8.
# Safe to run at any point, including before anything has been installed.
set -euo pipefail

echo "==> Removing PipeWire drop-ins"
rm -f ~/.config/pipewire/pipewire.conf.d/10-discord-sink.conf
rm -f ~/.config/pipewire/pipewire.conf.d/20-discord-loopback.conf
rm -f ~/.config/pipewire/pipewire-pulse.conf.d/50-discord-target.conf

echo "==> Removing EasyEffects user unit"
systemctl --user disable --now easyeffects.service 2>/dev/null || true
rm -f ~/.config/systemd/user/easyeffects.service
systemctl --user daemon-reload

# Also stop any EasyEffects started OUTSIDE systemd (manual launch / setsid).
# systemctl cannot see those, and a stray instance flushes its in-memory
# settings on exit -- silently undoing the revert below. Quit must happen
# BEFORE the edit so the flush lands first.
easyeffects --quit >/dev/null 2>&1 || true
sleep 2

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
