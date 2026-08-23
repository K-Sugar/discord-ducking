#!/usr/bin/env bash
# Install Discord voice ducking. Idempotent; safe to re-run.
# See docs/DESIGN.md for why each piece is shaped the way it is.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.local/share/discord-ducking/backup-$STAMP"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  !! %s\033[0m\n' "$*" >&2; exit 1; }

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

say "Checking dependencies"
for c in pipewire wireplumber pactl pw-link easyeffects; do
  command -v "$c" >/dev/null || die "missing '$c'. Install with: sudo pacman -S --needed easyeffects lsp-plugins-lv2"
done
[ -d /usr/lib/lv2/lsp-plugins.lv2 ] || warn "lsp-plugins-lv2 not found; EasyEffects' built-in compressor still works"
ok "dependencies present"
pactl info 2>/dev/null | grep -q 'on PipeWire' || die "not running on PipeWire"

say "Backing up existing config to $BACKUP"
mkdir -p "$BACKUP"
for f in ~/.config/pipewire/pipewire.conf.d/10-discord-sink.conf \
         ~/.config/pipewire/pipewire.conf.d/20-discord-loopback.conf \
         ~/.config/systemd/user/easyeffects.service \
         ~/.config/easyeffects/db/easyeffectsrc \
         ~/.config/easyeffects/db/compressorrc; do
  [ -e "$f" ] && cp -a "$f" "$BACKUP/" && ok "backed up $(basename "$f")"
done
ok "backup dir: $BACKUP"

say "Installing PipeWire drop-ins"
mkdir -p ~/.config/pipewire/pipewire.conf.d
install -m644 "$REPO/config/pipewire/pipewire.conf.d/10-discord-sink.conf"     ~/.config/pipewire/pipewire.conf.d/
install -m644 "$REPO/config/pipewire/pipewire.conf.d/20-discord-loopback.conf" ~/.config/pipewire/pipewire.conf.d/
ok "10-discord-sink.conf, 20-discord-loopback.conf"

say "Stopping EasyEffects before touching its config"
# A running instance keeps settings in memory and overwrites the file on exit.
stop_easyeffects
ok "stopped"

say "Merging EasyEffects settings (existing effects preserved)"
python3 - <<'PY'
import configparser, pathlib, sys
db = pathlib.Path.home()/".config/easyeffects/db"
db.mkdir(parents=True, exist_ok=True)

ee = db/"easyeffectsrc"
c = configparser.ConfigParser(); c.optionxform = str
if ee.exists(): c.read(ee)
if not c.has_section("StreamOutputs"): c.add_section("StreamOutputs")

c.set("StreamOutputs", "processAllOutputs", "true")
c.set("StreamOutputs", "useDefaultOutputDevice", "true")

# union the blocklist so the user's own exclusions survive
need = ["Discord", "WEBRTC VoiceEngine", "discord_direct_playback"]
cur = [x.strip() for x in c.get("StreamOutputs", "blocklist", fallback="").split(",") if x.strip()]
for n in need:
    if n not in cur: cur.append(n)
c.set("StreamOutputs", "blocklist", ",".join(cur))

# append our compressor only if not already in the chain
plugins = [x.strip() for x in c.get("StreamOutputs", "plugins", fallback="").split(",") if x.strip()]
if "compressor#0" not in plugins:
    plugins.append("compressor#0")
    print("   added compressor#0 to the output chain")
else:
    print("   compressor#0 already present - leaving chain order alone")
c.set("StreamOutputs", "plugins", ",".join(plugins))
with ee.open("w") as f: c.write(f, space_around_delimiters=False)
print("   easyeffectsrc merged")
PY

say "Writing compressor parameters"
python3 - "$REPO" <<'PY'
import configparser, pathlib, sys
repo = pathlib.Path(sys.argv[1])
db   = pathlib.Path.home()/".config/easyeffects/db"
dst  = db/"compressorrc"
src  = repo/"config/easyeffects/compressorrc"
c = configparser.ConfigParser(); c.optionxform = str; c.read(src)
d = configparser.ConfigParser(); d.optionxform = str
if dst.exists(): d.read(dst)
for s in c.sections():
    if not d.has_section(s): d.add_section(s)
    for k, v in c.items(s): d.set(s, k, v)
with dst.open("w") as f: d.write(f, space_around_delimiters=False)
print("   compressorrc written (threshold MUST be calibrated - see step 3 below)")
PY

say "Installing systemd user unit"
mkdir -p ~/.config/systemd/user
install -m644 "$REPO/config/systemd/user/easyeffects.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable easyeffects.service >/dev/null 2>&1
ok "easyeffects.service enabled (graphical-session.target)"

say "Restarting audio stack"
systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 4
for u in pipewire pipewire-pulse wireplumber; do
  [ "$(systemctl --user is-active $u)" = active ] || die "$u failed to start! Run scripts/uninstall.sh and check: journalctl --user -u $u -n 50"
done
ok "pipewire, pipewire-pulse, wireplumber active"
systemctl --user start easyeffects.service || warn "easyeffects.service did not start (no graphical session?)"
sleep 5

say "Verifying"
"$REPO/scripts/verify.sh" || warn "verification reported problems - see above"

cat <<'MSG'

============================================================
 Installed. THREE manual steps remain:

 1. RESTART DISCORD if it was already running - it caches its
    audio device list at startup and will not show a new sink.
    Then: Discord -> Settings -> Voice & Video -> Output Device
       select  "Discord (ducking source)"

 2. Play some audio and join a call to confirm routing:
       scripts/verify.sh

 3. CALIBRATE THE THRESHOLD - do not skip this.
    The correct value is machine-specific. On the reference
    system real speech peaked at -34.8 dBFS, so the commonly
    suggested -30 dB threshold NEVER triggered.
       scripts/measure-sidechain.sh      # while someone talks
    then set the threshold it recommends.

 Optional end-to-end proof:  scripts/test-ducking.sh
 To remove everything:       scripts/uninstall.sh
============================================================
MSG
