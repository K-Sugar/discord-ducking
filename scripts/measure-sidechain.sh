#!/usr/bin/env bash
# Measure the real signal level on DiscordSink.monitor and recommend a threshold.
#
# WHY THIS EXISTS: the correct compressor threshold is machine-specific. On the
# reference system, real speech peaked at -34.8 dBFS, so the commonly suggested
# -30 dB threshold never triggered even once. Guessing wastes hours; measure.
#
# Usage: scripts/measure-sidechain.sh [seconds]     (default 15)
#        Run it while someone is ACTUALLY TALKING in a Discord call.
set -euo pipefail
DUR="${1:-15}"
OUT="$(mktemp -d)/sidechain.wav"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

command -v pw-record >/dev/null || { echo "pw-record not found"; exit 1; }
pactl list sinks short | grep -q '\bDiscordSink\b' || { echo "DiscordSink missing - run install.sh first"; exit 1; }
python3 -c 'import numpy' 2>/dev/null || { echo "needs numpy: sudo pacman -S --needed python-numpy"; exit 1; }

echo "Recording DiscordSink.monitor for ${DUR}s - make sure someone is TALKING now..."
# NOTE: '--target DiscordSink.monitor' would silently record the DEFAULT SOURCE
# (your microphone) instead. stream.capture.sink=true is mandatory. DESIGN.md §3.10
timeout "$((DUR+1))" pw-record --target DiscordSink -P 'stream.capture.sink=true' "$OUT" 2>/dev/null || true

python3 - "$OUT" <<'PY'
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); sr = w.getframerate(); n = w.getnframes(); ch = w.getnchannels()
d = np.frombuffer(w.readframes(n), dtype=np.int16).astype(float)/32768.0
if n == 0: print("No audio captured."); sys.exit(1)
d = d.reshape(-1, ch).mean(axis=1)
win = int(sr*0.010)                      # 10 ms, matches sidechainReactivity
r  = np.array([np.sqrt((d[i:i+win]**2).mean()) for i in range(0, len(d)-win, win)])
db = 20*np.log10(np.maximum(r, 1e-12))
print(f"\n  captured {n/sr:.1f}s\n")
print("  level distribution (10 ms RMS windows)")
for p in (50, 75, 90, 95, 99):
    print(f"    {p:2d}th percentile : {np.percentile(db, p):7.2f} dBFS")
print(f"    peak            : {db.max():7.2f} dBFS")
floor  = np.percentile(db, 50)
speech = np.percentile(db, 95)
if db.max() < -70:
    print("\n  Nothing but silence - was anyone actually talking?"); sys.exit(1)
if speech - floor < 6:
    print("\n  WARNING: speech and noise floor are too close to separate cleanly.")
rec = round((floor + speech)/2)
print(f"\n  noise floor (median)   : {floor:7.2f} dBFS")
print(f"  speech (95th pct)      : {speech:7.2f} dBFS")
print(f"\n  RECOMMENDED threshold  : {rec} dB")
print(f"    (midway between floor and speech; raise it if background noise ducks,")
print( "     lower it if quiet talkers do not trigger)")
print(f"\n  Apply with:")
print(f"    systemctl --user stop easyeffects")
print(f"    sed -i 's/^threshold=.*/threshold={rec}/' ~/.config/easyeffects/db/compressorrc")
print(f"    systemctl --user start easyeffects")
PY
