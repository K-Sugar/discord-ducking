#!/usr/bin/env bash
# End-to-end proof that ducking works, without needing anyone to talk.
#
# Injects a 440 Hz tone into easyeffects_sink ("music") and a 1000 Hz tone into
# DiscordSink ("voice"), captures the hardware sink monitor, and compares the
# per-frequency levels with and without the Discord tone. Two distinct
# frequencies let the ducked signal and the trigger be measured independently.
#
# Usage: scripts/test-ducking.sh [trigger_dbfs]   default -37 (realistic speech)
set -euo pipefail
TRIG="${1:--37}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 -c 'import numpy' 2>/dev/null || { echo "needs numpy: sudo pacman -S --needed python-numpy"; exit 1; }
HW="$(pactl get-default-sink)"
echo "hardware sink: $HW   trigger level: ${TRIG} dBFS"
echo "You will hear test tones for ~12 seconds."

python3 - "$T" "$TRIG" <<'PY'
import sys, wave, math, struct
T, trig = sys.argv[1], float(sys.argv[2])
def tone(path, freq, rms_dbfs, dur=30, sr=48000):
    amp = min(10**(rms_dbfs/20)*math.sqrt(2), 0.99)
    w = wave.open(path,"w"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b"".join(struct.pack("<hh", *(int(amp*32767*math.sin(2*math.pi*freq*n/sr)),)*2)
                           for n in range(sr*dur)))
    w.close()
tone(f"{T}/music.wav", 440, -17)
tone(f"{T}/voice.wav", 1000, trig)
PY

pw-play --target easyeffects_sink "$T/music.wav" & M=$!
sleep 2
timeout 4 pw-record --target "$HW" -P 'stream.capture.sink=true' "$T/before.wav" 2>/dev/null
pw-play --target DiscordSink "$T/voice.wav" & D=$!
sleep 2
timeout 4 pw-record --target "$HW" -P 'stream.capture.sink=true' "$T/after.wav" 2>/dev/null
kill $M $D 2>/dev/null || true; wait 2>/dev/null || true

python3 - "$T" <<'PY'
import sys, wave, numpy as np
T = sys.argv[1]
def band(p, f0, bw=30.0, win=8192):
    w = wave.open(p); sr=w.getframerate(); n=w.getnframes(); ch=w.getnchannels()
    d = np.frombuffer(w.readframes(n), dtype=np.int16).astype(float)/32768.0
    d = d.reshape(-1, ch)[:, 0][int(sr*0.7):]
    fr = np.fft.rfftfreq(win, 1/sr); sel = (fr >= f0-bw) & (fr <= f0+bw); v=[]
    for i in range(0, len(d)-win, win//2):
        v.append((np.abs(np.fft.rfft(d[i:i+win]*np.hanning(win)))/(win/4))[sel].max())
    return 20*np.log10(max(np.mean(v), 1e-12))
m0, m1 = band(f"{T}/before.wav",440),  band(f"{T}/after.wav",440)
v0, v1 = band(f"{T}/before.wav",1000), band(f"{T}/after.wav",1000)
print(f"\n  440 Hz  music   : {m0:7.2f} -> {m1:7.2f} dBFS   ({m1-m0:+.2f} dB)")
print(f"  1000 Hz discord : {v0:7.2f} -> {v1:7.2f} dBFS   ({v1-v0:+.2f} dB)")
duck = m1-m0
print()
if duck < -5:
    print(f"  RESULT: ducking works - music attenuated by {-duck:.1f} dB")
else:
    print(f"  RESULT: NO DUCKING ({duck:+.1f} dB).")
    print("          Threshold is probably too high. Run scripts/measure-sidechain.sh")
PY
