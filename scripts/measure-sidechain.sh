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

echo "Recording DiscordSink.monitor for ${DUR}s - make sure someone is TALKING now..."
# NOTE: '--target DiscordSink.monitor' would silently record the DEFAULT SOURCE
# (your microphone) instead. stream.capture.sink=true is mandatory. DESIGN.md §3.10
timeout "$((DUR+1))" pw-record --target DiscordSink -P 'stream.capture.sink=true' "$OUT" 2>/dev/null || true

python3 - "$OUT" <<'PYEOF'
# Deliberately stdlib-only. This is the one tool nobody may skip, so it must not
# pull in numpy (49 MiB, plus cblas/lapack, for a 50 KB package). The optional
# test-ducking.sh keeps numpy for its FFT.
import sys, wave, math
from array import array

w = wave.open(sys.argv[1]); sr = w.getframerate(); n = w.getnframes(); ch = w.getnchannels()
if n == 0:
    print("No audio captured."); sys.exit(1)
if w.getsampwidth() != 2:
    print(f"Unexpected sample width {w.getsampwidth()*8}-bit; expected 16-bit."); sys.exit(1)

a = array('h'); a.frombytes(w.readframes(n))
if sys.byteorder == 'big': a.byteswap()

if ch > 1:
    mono = [sum(a[i:i+ch]) / ch for i in range(0, len(a) - ch + 1, ch)]
else:
    mono = a

win = int(sr * 0.010)                      # 10 ms, matches sidechainReactivity
db = []
for i in range(0, len(mono) - win, win):
    acc = 0.0
    for v in mono[i:i+win]:
        x = v / 32768.0
        acc += x * x
    db.append(20 * math.log10(max(math.sqrt(acc / win), 1e-12)))

if not db:
    print("Recording too short to analyse."); sys.exit(1)

def pct(sorted_vals, p):
    if len(sorted_vals) == 1: return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (p / 100.0)
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi: return sorted_vals[int(k)]
    return sorted_vals[lo] * (hi - k) + sorted_vals[hi] * (k - lo)

sdb = sorted(db)
print(f"\n  captured {n/sr:.1f}s\n")
print("  level distribution (10 ms RMS windows)")
for p in (50, 75, 90, 95, 99):
    print(f"    {p:2d}th percentile : {pct(sdb, p):7.2f} dBFS")
peak = sdb[-1]
print(f"    peak            : {peak:7.2f} dBFS")

speech = pct(sdb, 95)
if peak < -70:
    print("\n  Nothing but silence - was anyone actually talking?"); sys.exit(1)

# DiscordSink is a NULL sink: with no Discord audio its monitor is EXACT digital
# silence, so those windows floor at -240 dBFS and would drag the median to a
# meaningless value (and the recommendation with it). Derive the noise floor only
# from windows that actually carry signal.
SILENCE = -100.0
signal = sorted(d for d in db if d > SILENCE)
quiet_frac = 1.0 - (len(signal) / len(db))

if len(signal) < max(5, int(0.02 * len(db))):
    floor = None
    rec = round(speech - 12)
else:
    floor = pct(signal, 50)
    if speech - floor < 6:
        # Too close to separate: a midpoint would land essentially AT speech level
        # and would barely trigger. Sit a fixed margin below speech instead.
        print("\n  WARNING: speech and noise floor are too close to separate cleanly.")
        rec = round(speech - 12)
    else:
        # never recommend absurdly far below speech, whatever the floor says
        rec = max(round((floor + speech) / 2), round(speech - 25))

if quiet_frac > 0.01:
    print(f"\n  digital silence        : {quiet_frac*100:5.1f}% of windows (Discord idle)")
if floor is None:
    print("  noise floor            :  n/a - monitor was digitally silent between bursts")
    print("                            using (speech - 12 dB) instead")
else:
    print(f"  noise floor (median)   : {floor:7.2f} dBFS")
print(f"  speech (95th pct)      : {speech:7.2f} dBFS")
print(f"\n  RECOMMENDED threshold  : {rec} dB")
print( "    (midway between floor and speech; raise it if background noise ducks,")
print( "     lower it if quiet talkers do not trigger)")
print( "\n  Apply with:")
print( "    systemctl --user stop easyeffects")
print(f"    sed -i 's/^threshold=.*/threshold={rec}/' ~/.config/easyeffects/db/compressorrc")
print( "    systemctl --user start easyeffects")
PYEOF
