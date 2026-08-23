# Build Checklist — Discord Voice Ducking

Spec: `DESIGN.md`. Do not proceed past a failed gate. Mark `[x]` only after the gate passes.

**Standing rule:** after every `systemctl --user restart wireplumber pipewire pipewire-pulse`, run
`journalctl --user -u pipewire -n 50` and confirm the units came back up *before* doing anything
else. A malformed drop-in leaves the machine with no audio at all.

---

## Step 0 — Rollback first  (DESIGN §6.0, §8)  ✅ DONE 2026-08-23
- [x] Write `scripts/uninstall.sh` per §8
- [x] `chmod +x rollback.sh`
- [x] **GATE:** script exists, is executable, and runs safely when nothing is installed yet

## Step 1 — Install packages  (§6.1)  ✅ DONE 2026-08-23
- [x] `sudo pacman -S --needed easyeffects lsp-plugins-lv2`  (needed full `-Syu` + reboot first — partial-upgrade block)
- [x] **GATE:** `easyeffects 8.2.8-1.1` + `lsp-plugins-lv2 1.2.33-2.1` installed; `easyeffects --version` runs
- [x] **GATE:** service flag confirmed = `--service-mode` (`--gapplication-service` is deprecated in 8.2.8)

## Step 2 — RISK GATE R1  (§6.2)  ✅ PASSED 2026-08-23 — design confirmed sound
- [x] Launch EasyEffects, enable "Process all output streams", keep the real device as default sink
- [x] Start audio (Zen + spotifyd live, plus a `pw-play` test tone)
- [x] **GATE PASSED:** all 4 streams moved to `easyeffects_sink` (id 508) while default sink stayed `bluez_output...`
- [x] ~~IF THIS FAILS: STOP AND REPORT~~ — not needed, R1 passed. Design confirmed sound.
- [x] Turned `processAllOutputs=false` and quit EE; `easyeffects_sink` gone, streams back on hardware sink

## Step 3 — Null sink  (§4.1, §6.3)  ✅ DONE 2026-08-23
- [x] `mkdir -p ~/.config/pipewire/pipewire.conf.d`
- [x] Write `10-discord-sink.conf`
- [x] Restart units + check journal (clean)
- [x] **GATE:** `wpctl status` lists `DiscordSink` (id 31, "Discord (ducking source)")
- [x] **GATE:** `DiscordSink.monitor` present

## Step 4 — Loopback  (§4.2, §6.4)  ✅ DONE 2026-08-23
- [x] Write `20-discord-loopback.conf` — no `target.object`, no `node.dont-reconnect`
- [x] Restart units + check journal (clean)
- [x] **GATE:** `pw-link -l` shows the full chain linked
- [x] **GATE PASSED (§3.1 acceptance test):** verified across Bluetooth -> HDMI -> Bluetooth -> S/PDIF -> Bluetooth. Note: USB Speaker/Headphones ports are `not available` (jacks empty) so cannot be made default — pre-existing, unrelated.

## Step 5 — Route Discord  (§4.3, §6.5)  ✅ DONE 2026-08-23
- [x] Discord → Voice & Video → Output Device → "Discord (ducking source)"
- [x] **GATE PASSED:** playback `target=DiscordSink`, sink-input #340 -> sink 32 (DiscordSink), state=running
- [x] **GATE PASSED:** capture stream `target=alsa_input...USB_Mic...` — untouched
- [x] ~~pulse.rules fallback~~ — not needed, in-app selector worked

## Step 6 — Compressor  (§4.4, §6.6)  ✅ DONE 2026-08-23
- [x] Compressor added; `sidechainType=2` (External), `sidechainInputDevice=DiscordSink`, `sidechainMode=1` (RMS)
- [x] Params written to `~/.config/easyeffects/db/compressorrc` section `[soe][Compressor#0]`
- [x] Blocklist = `Discord,WEBRTC VoiceEngine,discord_direct_playback` — **matched on `node.name`, see §3.7**
- [x] `processAllOutputs=true` set after the blocklist
- [x] `useDefaultOutputDevice=true` verified surviving round-trips
- [x] `~/.config/systemd/user/easyeffects.service` installed, enabled + active (Qt6 needs session env; `WantedBy=graphical-session.target`)
- [x] KDE: unit enabled + active, `graphical-session.target` active, display env exported
- [x] ~~**GATE:** unit starts cleanly in the **Caelestia** session~~ — **N/A: dropped by the user
  2026-08-23, not a use case.** Never tested, and deliberately so. If it is ever needed, check
  `systemctl --user is-active graphical-session.target` there; if that session does not activate it,
  use EasyEffects' own autostart toggle instead.
- [x] **GATE PASSED:** `DiscordSink:monitor_FL/FR -> ee_soe_compressor:probe_FL/FR`
- [x] **GATE PASSED:** `easyeffects_sink:monitor -> ee_soe_compressor:input`, output to hardware
- [x] **GATE PASSED (§3.6/§3.7):** `discord_direct_playback` on HARDWARE, not `easyeffects_sink` — required bisecting the match key
- [x] Schema captured in DESIGN §4.4.1/§3.7; config backups in scratchpad

## Step 7 — Tune  (§6.7)  ✅ DONE 2026-08-23 — user-approved
- [x] Threshold set from measured sidechain distribution: `-50` (brief's `-30` never triggered — 0.0% of speech crossed it). Ratio raised to `12`.
- [x] Release set to 700 ms by user
- [x] Ratio 24:1, threshold -50 — user reports working well
- [x] **GATE (instrumented):** -12.12 dB duck at realistic speech level (-37 dBFS trigger); Discord itself unducked
- [x] **GATE PASSED:** user confirms working on a live call

## Step 8 — Verify R2  (§6.8)  ✅ DONE 2026-08-23
- [x] **GATE PASSED:** Discord screen-share-with-audio still captures app audio after re-routing —
  user-confirmed. R2 closed; the capture taps application output nodes directly, so moving those
  apps onto `easyeffects_sink` does not disturb it.

## Step 9 — Full-cycle test  (§6.9)  ✅ DONE 2026-08-23 — all gates user-confirmed
- [x] Reboot
- [x] **GATE:** `DiscordSink` and `easyeffects_sink` both exist with no manual intervention
- [x] **GATE:** music/game audio lands on `easyeffects_sink`
- [x] **GATE:** Discord lands on `DiscordSink`
- [x] **GATE:** someone speaks → other audio ducks, Discord voice does NOT
- [x] **GATE:** silence → other audio recovers
- [x] **GATE:** quit and restart Discord → routing holds
- [x] **GATE:** switch output device mid-session → everything follows
- [x] **GATE:** no A2DP→HFP profile switch during a call (separate USB mic prevents it).
  Note: a device that *connects* while an app is already recording can still negotiate as a
  headset and offer no A2DP profile — `discord-ducking bt-mic status` detects that; reconnect fixes it.

## Step 10 — Hand back  ✅ DONE 2026-08-23
- [x] Audited 2026-08-23: all 5 created files covered; `stream-properties` confirmed untouched; no system files modified
- [x] Final values recorded in DESIGN §4.4.2


---

## STATUS 2026-08-23 — COMPLETE

**All gates passed. Feature working, user-confirmed, and running on a second machine.**

Every success criterion from the brief is met:

1. Speech ducks other audio — measured at −12.1 dB with a realistic −37 dBFS trigger, and confirmed
   by ear on live calls.
2. Discord is never ducked by its own signal — structural, since it bypasses the compressor.
3. Added latency on the voice path is negligible; the sidechain taps upstream of the loopback, so
   the duck engages marginally *ahead* of the audible voice.
4. Survives reboot with no manual steps.
5. Survives output-device switching — no device name is hardcoded anywhere.
6. `scripts/uninstall.sh` tears it down in one command, verified by a full clean-slate cycle.

Shipped beyond the original brief: MIT licensed, packaged for Arch (`makepkg -si`), a
`discord-ducking` CLI, calibration and health-check tooling, a Bluetooth A2DP/headset toggle, and
installation confirmed working on a friend's CachyOS machine.

The one item never tested is the Caelestia session check (Step 6), dropped by the user as not a use
case rather than passed.
